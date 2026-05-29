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
  ASSETS?: Fetcher          // bundled install.sh asset
  HUB_OWNER: string         // "TeoSlayer"
  HUB_REPO: string          // "pilotprotocol"
  ORG: string               // "pilot-protocol"
}

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

async function serveInstallSh(env: Env, _ctx: ExecutionContext, url: URL): Promise<Response> {
  if (env.ASSETS) {
    return env.ASSETS.fetch(new Request(new URL('/install.sh', url.origin).toString()))
  }
  // Fallback during local dev or when ASSETS isn't bound
  return new Response('install.sh asset not configured', { status: 501 })
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
