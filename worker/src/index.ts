/**
 * pilotprotocol.network — the only deployed surface that needs custom code.
 *
 * What this Worker serves:
 *
 *   GET /install.sh
 *     Static install script. Returns from R2 (or the bundled asset).
 *
 *   GET /.well-known/latest.json
 *     The release manifest, computed on-demand from web4 GitHub releases.
 *     The result is cached for 60 s in Cloudflare's edge cache.
 *     install.sh fetches this URL on every invocation.
 *
 *   GET /.well-known/cascade-status.json
 *     Operator-facing snapshot: which sibling cascades are in flight,
 *     which have completed, recent failures. Built from workflow_runs.
 *     Cached for 30 s.
 *
 * There is no manifest file checked in anywhere. The single source of
 * truth is `git tag` on each repo + GitHub Release metadata on web4.
 * This Worker is a render of that state.
 */

export interface Env {
  GH_TOKEN: string
  ASSETS?: R2Bucket         // install.sh asset in R2
  AI?: Ai                   // Workers AI binding (llama-3.1-8b-instruct etc.)
  HUB_OWNER: string         // "TeoSlayer"
  HUB_REPO: string          // "pilotprotocol"
  ORG: string               // "pilot-protocol"
  CHANGELOG_SECRET?: string // HMAC key shared with CI workflows
}

// Repos allowed to receive changelog generation. Anything outside this
// allowlist is rejected — keeps the LLM from being used for arbitrary
// repos and bounds the inferences-per-day burn.
const ALLOWED_REPOS = new Set([
  'TeoSlayer/pilotprotocol', 'TeoSlayer/homebrew-pilot',
  'pilot-protocol/app-store', 'pilot-protocol/beacon',
  'pilot-protocol/common', 'pilot-protocol/dataexchange',
  'pilot-protocol/eventstream', 'pilot-protocol/gateway',
  'pilot-protocol/handshake', 'pilot-protocol/libpilot',
  'pilot-protocol/nameserver', 'pilot-protocol/policy',
  'pilot-protocol/rendezvous', 'pilot-protocol/runtime',
  'pilot-protocol/skillinject', 'pilot-protocol/trustedagents',
  'pilot-protocol/updater', 'pilot-protocol/webhook',
  'pilot-protocol/examples', 'pilot-protocol/website',
  'pilot-protocol/release',
])

export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(req.url)
    try {
      switch (url.pathname) {
        case '/install.sh':
          return serveInstallSh(env, ctx, url)
        case '/.well-known/latest.json':
          return serveManifest(env, ctx, url)
        case '/.well-known/cascade-status.json':
          return serveCascadeStatus(env, ctx)
        case '/api/changelog':
          return serveChangelog(req, env, ctx)
        default:
          return new Response('not found', { status: 404 })
      }
    } catch (err) {
      return new Response(
        `error: ${(err as Error).message}`,
        { status: 502, headers: { 'content-type': 'text/plain' } }
      )
    }
  }
}

// ---------------------------------------------------------------------------
// /install.sh
// ---------------------------------------------------------------------------

async function serveInstallSh(env: Env, _ctx: ExecutionContext, _url: URL): Promise<Response> {
  if (!env.ASSETS) {
    return new Response('install.sh asset not configured', { status: 501 })
  }
  const obj = await env.ASSETS.get('install.sh')
  if (!obj) {
    return new Response('install.sh not found in R2', { status: 404 })
  }
  return new Response(obj.body, {
    headers: {
      'content-type': 'text/plain; charset=utf-8',
      'cache-control': 'public, max-age=300',
      'etag': obj.httpEtag,
    },
  })
}

// ---------------------------------------------------------------------------
// /.well-known/latest.json
// ---------------------------------------------------------------------------

type GHRelease = {
  tag_name: string
  prerelease: boolean
  draft: boolean
  assets: { name: string, browser_download_url: string }[]
}

async function serveManifest(env: Env, ctx: ExecutionContext, _url: URL): Promise<Response> {
  const cache = caches.default
  const cacheKey = new Request('https://internal/manifest', { method: 'GET' })

  const cached = await cache.match(cacheKey)
  if (cached) return cached

  // Fetch the most recent ~20 releases — enough to find latest stable + latest beta.
  const releases: GHRelease[] = await ghAPI(
    env,
    `repos/${env.HUB_OWNER}/${env.HUB_REPO}/releases?per_page=20`
  )

  const stable = releases.find(r => !r.prerelease && !r.draft)
  const beta   = releases.find(r => r.prerelease && !r.draft) ?? stable

  if (!stable) {
    return new Response(JSON.stringify({ error: 'no stable release' }), {
      status: 503,
      headers: { 'content-type': 'application/json' }
    })
  }

  // Fetch checksums.txt from the stable release to populate per-platform
  // urls + sha256. checksums.txt is one line per artifact: "<sha>  <name>".
  const platforms = await collectPlatforms(env, env.HUB_OWNER, env.HUB_REPO, stable)

  const manifest = {
    $schema: 'https://pilotprotocol.network/.well-known/latest.schema.json',
    generated_at: new Date().toISOString(),
    latest_stable: stable.tag_name,
    latest_beta:   beta?.tag_name ?? stable.tag_name,
    channels: {
      stable: stable.tag_name,
      beta:   beta?.tag_name ?? stable.tag_name,
    },
    release_notes_url: `https://github.com/${env.HUB_OWNER}/${env.HUB_REPO}/releases/tag/${stable.tag_name}`,
    homebrew_formula_url: 'https://github.com/TeoSlayer/homebrew-pilot/raw/main/Formula/pilotprotocol.rb',
    platforms,
  }

  const res = new Response(JSON.stringify(manifest, null, 2), {
    headers: {
      'content-type': 'application/json',
      'cache-control': 'public, max-age=60',
      'access-control-allow-origin': '*',
    },
  })
  ctx.waitUntil(cache.put(cacheKey, res.clone()))
  return res
}

async function collectPlatforms(
  env: Env, owner: string, repo: string, release: GHRelease,
): Promise<Record<string, { url: string, sha256: string }>> {
  const checksumsAsset = release.assets.find(a => a.name === 'checksums.txt')
  const out: Record<string, { url: string, sha256: string }> = {}
  if (!checksumsAsset) return out

  const checksumsText = await fetch(checksumsAsset.browser_download_url).then(r => r.text())
  // Format: "<sha256>  <filename>"
  for (const line of checksumsText.split('\n')) {
    const m = line.trim().match(/^([0-9a-f]{64})\s+(\S+)$/)
    if (!m) continue
    const [, sha, name] = m
    // Strip "pilot-" prefix and ".tar.gz" suffix to get the platform key.
    const platform = name.replace(/^pilot-/, '').replace(/\.tar\.gz$/, '')
    const url = `https://github.com/${owner}/${repo}/releases/download/${release.tag_name}/${name}`
    out[platform] = { url, sha256: sha }
  }
  return out
}

// ---------------------------------------------------------------------------
// /.well-known/cascade-status.json
// ---------------------------------------------------------------------------

async function serveCascadeStatus(env: Env, ctx: ExecutionContext): Promise<Response> {
  const cache = caches.default
  const cacheKey = new Request('https://internal/cascade-status', { method: 'GET' })

  const cached = await cache.match(cacheKey)
  if (cached) return cached

  // Pull the 20 most recent orchestrator runs and bucket by status.
  const runs: any = await ghAPI(
    env,
    `repos/${env.ORG}/release/actions/workflows/orchestrator.yml/runs?per_page=20`
  )

  const bucket: Record<string, any[]> = { in_progress: [], completed: [], failed: [] }
  for (const r of runs.workflow_runs ?? []) {
    const target =
      r.conclusion === 'failure' ? 'failed' :
      r.status === 'completed'   ? 'completed' :
      'in_progress'
    bucket[target].push({
      package: r.display_title?.replace(/^cascade-/, '').split('-')[0] ?? '',
      tag:     r.display_title ?? '',
      status:  r.status,
      conclusion: r.conclusion,
      started: r.created_at,
      url:     r.html_url,
    })
  }

  const body = JSON.stringify({
    generated_at: new Date().toISOString(),
    in_progress: bucket.in_progress,
    completed:   bucket.completed.slice(0, 5),
    failed:      bucket.failed.slice(0, 5),
  }, null, 2)

  const res = new Response(body, {
    headers: {
      'content-type': 'application/json',
      'cache-control': 'public, max-age=30',
      'access-control-allow-origin': '*',
    },
  })
  ctx.waitUntil(cache.put(cacheKey, res.clone()))
  return res
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

async function ghAPI(env: Env, path: string): Promise<any> {
  const res = await fetch(`https://api.github.com/${path}`, {
    headers: {
      'user-agent':  'pilot-release-worker',
      'accept':      'application/vnd.github+json',
      'authorization': `Bearer ${env.GH_TOKEN}`,
    },
  })
  if (!res.ok) {
    throw new Error(`gh API ${path}: ${res.status} ${res.statusText}`)
  }
  return res.json()
}

// ---------------------------------------------------------------------------
// /api/changelog
// ---------------------------------------------------------------------------

interface ChangelogRequest {
  repo: string                // "pilot-protocol/gateway"
  tag: string                 // "v0.2.1-beta.3"
  previous_tag?: string       // tag we're diffing against; defaults to highest stable
  upstream_pkg?: string       // "common" — what triggered the cascade bump
  upstream_version?: string   // "v0.4.0" — its tag
}

interface ChangelogResponse {
  summary: string
  upstream_pkg?: string
  upstream_version?: string
  commit_count: number
  cached: boolean
}

async function serveChangelog(req: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
  // --- 1. Method + auth gate ----------------------------------------------
  if (req.method !== 'POST') {
    return json({ error: 'POST only' }, 405)
  }

  const bodyText = await req.text()

  // HMAC-SHA256(body, CHANGELOG_SECRET) — only callers with the shared
  // secret may invoke. Stops anonymous callers from burning AI credits.
  if (!env.CHANGELOG_SECRET) {
    return json({ error: 'CHANGELOG_SECRET not configured on this worker' }, 500)
  }
  const sigHeader = req.headers.get('x-signature') ?? ''
  const valid = await verifyHMAC(env.CHANGELOG_SECRET, bodyText, sigHeader)
  if (!valid) {
    return json({ error: 'invalid signature' }, 401)
  }

  // --- 2. Parse + validate inputs -----------------------------------------
  let body: ChangelogRequest
  try {
    body = JSON.parse(bodyText)
  } catch {
    return json({ error: 'invalid JSON body' }, 400)
  }

  if (!body.repo || !body.tag) {
    return json({ error: 'repo and tag are required' }, 400)
  }
  if (!ALLOWED_REPOS.has(body.repo)) {
    return json({ error: `repo not in allowlist: ${body.repo}` }, 403)
  }
  if (!/^v\d+\.\d+\.\d+(-[a-z]+\.\d+)?$/.test(body.tag)) {
    return json({ error: `tag does not match expected semver shape: ${body.tag}` }, 400)
  }

  if (!env.AI) {
    return json({ error: 'AI binding not configured on this worker' }, 500)
  }

  // --- 3. Cache check -----------------------------------------------------
  // Per-tag cache: if we already generated a summary for this tag, return
  // it instead of paying for the same inference twice.
  const cache = caches.default
  const cacheKey = new Request(`https://internal/changelog/${body.repo}/${body.tag}`)
  const cached = await cache.match(cacheKey)
  if (cached) {
    const data = await cached.json() as ChangelogResponse
    return json({ ...data, cached: true }, 200)
  }

  // --- 4. Collect commits for the prompt ----------------------------------
  // Prefer the upstream commits (what TRIGGERED the bump). Falls back to
  // the receiver's own commits when this isn't a cascade tag.
  let commitLines: string[] = []
  let commitCount = 0
  let upstreamRepo: string | null = null
  let prevUpstream: string | null = null

  if (body.upstream_pkg && body.upstream_version) {
    // Cascade case — describe what the upstream actually changed.
    upstreamRepo = body.upstream_pkg.includes('/')
      ? body.upstream_pkg
      : `pilot-protocol/${body.upstream_pkg}`
    if (!ALLOWED_REPOS.has(upstreamRepo)) {
      return json({ error: `upstream repo not in allowlist: ${upstreamRepo}` }, 403)
    }
    prevUpstream = await findPreviousTag(env, upstreamRepo, body.upstream_version)
    if (prevUpstream) {
      try {
        const compare: any = await ghAPI(env, `repos/${upstreamRepo}/compare/${prevUpstream}...${body.upstream_version}`)
        commitLines = (compare.commits ?? [])
          .slice(0, 30)                                    // bound prompt size
          .map((c: any) => `- ${c.commit.message.split('\n')[0]}`)
        commitCount = compare.commits?.length ?? 0
      } catch (e) {
        // Fall through — we'll still try to summarize on metadata alone.
      }
    }
  } else {
    // Non-cascade tag — describe what THIS repo changed since previous_tag.
    const prev = body.previous_tag ?? await findPreviousTag(env, body.repo, body.tag)
    if (prev) {
      try {
        const compare: any = await ghAPI(env, `repos/${body.repo}/compare/${prev}...${body.tag}`)
        commitLines = (compare.commits ?? [])
          .slice(0, 30)
          .map((c: any) => `- ${c.commit.message.split('\n')[0]}`)
        commitCount = compare.commits?.length ?? 0
      } catch (e) {
        // continue with no commits
      }
    }
  }

  // --- 5. Build prompt + call LLM -----------------------------------------
  const context = body.upstream_pkg
    ? `${body.repo} ${body.tag} bumps ${body.upstream_pkg} to ${body.upstream_version}.`
    : `${body.repo} ${body.tag} is a direct release.`

  const prompt = `You write release summaries for engineers. Be specific, technical, and concise.

Context: ${context}

Commits that justify this release:
${commitLines.length ? commitLines.join('\n') : '(no commits available — explain based on context alone)'}

Write the summary in 1-2 SHORT sentences explaining WHY this release happened and what changed. No marketing language. No "we are excited to announce". Start directly with the change.`

  const aiResponse: any = await env.AI.run('@cf/meta/llama-3.1-8b-instruct', {
    messages: [{ role: 'user', content: prompt }],
    max_tokens: 200,
    temperature: 0.2,
  })

  let summary: string = (aiResponse.response ?? '').toString().trim()
  // Sanitize: strip backticks/triple-newlines to avoid breaking markdown.
  summary = summary.replace(/\n{3,}/g, '\n\n').slice(0, 600)

  const result: ChangelogResponse = {
    summary,
    upstream_pkg: body.upstream_pkg,
    upstream_version: body.upstream_version,
    commit_count: commitCount,
    cached: false,
  }

  // Cache for 1 day — the inputs (commits between two fixed tags) never change.
  const resp = json(result, 200, { 'cache-control': 'public, max-age=86400' })
  await cache.put(cacheKey, resp.clone())
  return resp
}

// findPreviousTag finds the tag immediately before `currentTag` in the
// repo's tag list, sorted by descending semver. Returns null when there's
// no earlier tag (first ever release).
async function findPreviousTag(env: Env, repo: string, currentTag: string): Promise<string | null> {
  try {
    const tags: any = await ghAPI(env, `repos/${repo}/tags?per_page=50`)
    const list = (tags ?? []).map((t: any) => t.name as string)
    // Stable sort by descending semver-ish ordering. Strip leading 'v'.
    list.sort((a: string, b: string) => semverCompare(b, a))
    const idx = list.indexOf(currentTag)
    if (idx >= 0 && idx + 1 < list.length) return list[idx + 1]
    // Otherwise return the first tag that's "less than" currentTag.
    return list.find((t: string) => semverCompare(t, currentTag) < 0) ?? null
  } catch {
    return null
  }
}

function semverCompare(a: string, b: string): number {
  const norm = (s: string) => s.replace(/^v/, '').split(/[.-]/).map(x => /^\d+$/.test(x) ? Number(x) : x)
  const aa = norm(a); const bb = norm(b)
  for (let i = 0; i < Math.max(aa.length, bb.length); i++) {
    const x = aa[i] ?? 0; const y = bb[i] ?? 0
    if (x === y) continue
    if (typeof x === 'number' && typeof y === 'number') return x - y
    return String(x).localeCompare(String(y))
  }
  return 0
}

// verifyHMAC compares the supplied X-Signature header (form "sha256=<hex>")
// against HMAC-SHA256(body, secret). Constant-time comparison.
async function verifyHMAC(secret: string, body: string, header: string): Promise<boolean> {
  const m = /^sha256=([0-9a-f]{64})$/i.exec(header)
  if (!m) return false
  const expected = m[1]
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  const sigBuf = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(body))
  const computed = [...new Uint8Array(sigBuf)]
    .map(b => b.toString(16).padStart(2, '0')).join('')
  // Constant-time compare
  if (computed.length !== expected.length) return false
  let diff = 0
  for (let i = 0; i < computed.length; i++) {
    diff |= computed.charCodeAt(i) ^ expected.charCodeAt(i)
  }
  return diff === 0
}

function json(data: unknown, status = 200, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'content-type': 'application/json',
      'access-control-allow-origin': '*',
      ...extraHeaders,
    },
  })
}
