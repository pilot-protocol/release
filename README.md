# pilot-protocol/release

The single repo that owns every release-related concern for Pilot Protocol.

## What lives here

```
.github/workflows/
  tag-bump.yml          Reusable workflow — Zone-1 receiver
  release-bump.yml      Reusable workflow — Zone-2/3 receiver (PR-coalescing)
  orchestrator.yml      package-released → BFS → wave-dispatch bump-upstream
  notify.yml            Reusable workflow — emit package-released
scripts/
  compute-closure.py    BFS over the live dependency graph
worker/
  src/index.ts          Cloudflare Worker — serves /install.sh + manifest
  wrangler.toml         Deployment config
policy.json             The only hand-maintained file (bump policy + zones)
install.sh              Canonical install script
```

## The model

Three rules. Everything else falls out.

1. **Cascade → beta.** Auto-bumps from upstream releases always tag a beta.
2. **Human → stable.** Stable tags are typed by a human or by `gh promote`.
3. **`stable_only` siblings skip beta dispatches.** One if-statement.

## Zones

| Zone | Repos | Cascade behavior |
|---|---|---|
| 0 | cosift, pilot-ca, wallet | No cascade |
| 1 | common, beacon, gateway, dataexchange, eventstream, handshake, nameserver, policy, rendezvous, runtime, skillinject, trustedagents, updater, webhook, libpilot, app-store, examples | Auto-bump + auto-tag beta |
| 2 | web4 | Auto-bump + open daily-coalesced PR |
| 3 | sdk-node, sdk-python, sdk-swift, homebrew-pilot | Auto-bump + open PR (homebrew-pilot is auto-commit) |
| 4 | website | Deploys from main; cascade does not apply |

## How a sibling onboards

Drop two files in the sibling's `.github/workflows/`:

```yaml
# cascade.yml
on: { repository_dispatch: { types: [bump-upstream] } }
jobs:
  bump:
    uses: pilot-protocol/release/.github/workflows/tag-bump.yml@main  # or release-bump.yml for Zone-2/3
    with:
      upstream: ${{ github.event.client_payload.upstream }}
      version:  ${{ github.event.client_payload.version }}
      is_prerelease: ${{ github.event.client_payload.is_prerelease }}
```

```yaml
# notify.yml — called by the sibling's existing release.yml on tag push
on:
  push: { tags: ['v*'] }
jobs:
  notify:
    uses: pilot-protocol/release/.github/workflows/notify.yml@main
    with: { package: 'beacon', version: ${{ github.ref_name }} }
    secrets:
      ORCH_TOKEN: ${{ secrets.ORCH_TOKEN }}
```

That's the entire integration. Five lines per workflow, two workflows.

## Promotion

```bash
# Manual promotion is just git:
git tag v0.5.0 v0.5.0-beta.7^{commit}
git push origin v0.5.0
```

The stable tag fires the sibling's `notify.yml` → orchestrator → cascade.
Receivers' `stable_only` gate already handles the upgrade correctly.

## What changes when

| Change | Where |
|---|---|
| Add/remove a dep | Edit `go.mod`. Graph regenerates next cascade. |
| Add a sibling | Drop the two workflow shims; add an entry to `policy.json`. |
| Change zone of a sibling | Edit `policy.json`. |
| Tweak bump logic | PR to `tag-bump.yml` or `release-bump.yml`. Every sibling picks it up at `@main`. |
| Tweak manifest shape | PR to `worker/src/index.ts`. |
| Change install URL | DNS only — `install.sh` lives at the same URL. |

## What is **not** here

- **No checked-in `deps.json`.** The graph is rebuilt from live `go.mod` files on every cascade.
- **No checked-in manifest.** The Worker computes it on each request from GitHub Releases.
- **No per-sibling workflow templates.** All siblings call the same four reusable workflows.

## Required setup (one-time)

- GitHub App `pilot-release-bot` installed on `TeoSlayer/*` and `pilot-protocol/*` with
  `contents:write`, `pull-requests:write`, `actions:read`, `metadata:read`, `repository_dispatch`.
- Repo secrets on `pilot-protocol/release`:
  - `RELEASE_APP_ID`, `RELEASE_APP_PRIVATE_KEY` — for the orchestrator's `actions/create-github-app-token@v1`.
- Per-sibling secret `ORCH_TOKEN` — an installation token of the same App.
- Cloudflare Worker `GH_TOKEN` — read-only, for the manifest API calls.
- DNS: `pilotprotocol.network/install.sh` and `/.well-known/*` routed through the Worker.

## Cost of the whole system

- 4 workflow files, ~250 lines of YAML
- 1 Python script, ~200 lines
- 1 TypeScript worker, ~150 lines
- 1 JSON policy file, ~50 lines
- 1 README

Six files. That's the entire release infrastructure for every Pilot Protocol repo.
