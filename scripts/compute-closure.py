#!/usr/bin/env python3
"""
compute-closure.py — derive the reverse-transitive closure of a
released package from live go.mod files across the org.

Output JSON shape:
  {
    "upstream": "common",
    "version":  "v0.5.0",
    "is_prerelease": false,
    "targets": [
      {"node": "beacon",    "repo": "pilot-protocol/beacon",    "depth": 1, "zone": 1, "stable_only": true},
      {"node": "handshake", "repo": "pilot-protocol/handshake", "depth": 1, "zone": 1, "stable_only": true},
      ...
    ]
  }

The graph is rebuilt from live go.mod files on every invocation. There
is no checked-in dependency state. The hand-maintained policy file
(policy.json) supplies zone + bump_policy + manual_nodes. Every other
attribute is derived.

Cycle-back guard: if a sibling's only path to the hub (web4) is a
test-only or indirect go.mod require, drop that edge. The cascade only
fires on real production-source dependencies.
"""
from __future__ import annotations
import argparse
import base64
import json
import re
import subprocess
import sys
import time
from collections import defaultdict, deque
from pathlib import Path


class TransientGHError(RuntimeError):
    """A gh call failed for a reason that is NOT 'resource not found'
    (rate limit, 5xx, network). Raised so the caller aborts the whole
    run instead of silently treating a real dependent as absent."""


def gh(cmd: list[str], *, allow_missing: bool = False) -> str:
    """Invoke gh and return stdout.

    On non-zero exit:
      - if stderr looks like a genuine 404 ('Not Found' / 'No such') AND
        allow_missing is set, return "" (the resource legitimately does
        not exist — e.g. a repo with no go.mod);
      - otherwise retry a few times with backoff, then raise
        TransientGHError. This is the H5 fix: the previous code swallowed
        EVERY error, so a rate-limit mid-walk made a real dependent look
        like it had no go.mod and dropped it from the cascade silently.
    """
    last = ""
    for attempt in range(4):
        proc = subprocess.run(cmd, text=True, capture_output=True)
        if proc.returncode == 0:
            return proc.stdout.strip()
        last = (proc.stderr or "").strip()
        low = last.lower()
        if "not found" in low or "no such" in low or "404" in low:
            if allow_missing:
                return ""
            # A 404 where we did not expect one (e.g. the org repo list)
            # is still fatal — do not retry, but do not pretend success.
            raise TransientGHError(f"unexpected 404 from {cmd!r}: {last}")
        # Transient: rate limit, 5xx, DNS, etc. Back off and retry.
        if attempt < 3:
            time.sleep(2 ** attempt)
    raise TransientGHError(f"gh failed after retries: {cmd!r}: {last}")


def list_org_repos(org: str) -> list[dict]:
    raw = gh(["gh", "repo", "list", org, "--json", "name,defaultBranchRef", "--limit", "200"])
    return json.loads(raw) if raw else []


def fetch_file(owner: str, repo: str, ref: str, path: str) -> str | None:
    """Fetch a repo file via the contents API. Returns None only when the
    file genuinely does not exist (404); transient failures raise
    TransientGHError up the stack (H5)."""
    out = gh(
        ["gh", "api", f"repos/{owner}/{repo}/contents/{path}?ref={ref}", "--jq", ".content"],
        allow_missing=True,
    )
    if not out:
        return None
    try:
        return base64.b64decode(out).decode("utf-8", errors="replace")
    except Exception:
        return None


def has_cascade_receiver(owner: str, repo: str, ref: str) -> bool:
    """True iff the repo has .github/workflows/cascade.yml — the only
    thing that can receive a bump-upstream dispatch. A node without it
    is not a cascade target; dispatching to it is a guaranteed no-op
    (204/403), which the pre-fix graph counted as a phantom ✓ target
    (pilot-verify, settler, wallet, app-template, cosift-app)."""
    return fetch_file(owner, repo, ref, ".github/workflows/cascade.yml") is not None


def parse_go_mod(text: str) -> dict:
    out = {"module": None, "requires": []}
    in_req = False
    for raw in text.splitlines():
        line = re.sub(r"//.*", "", raw).strip()
        if not line:
            continue
        if line.startswith("module "):
            out["module"] = line.split()[1].strip('"')
            continue
        if line.startswith("require ("):
            in_req = True
            continue
        if line == ")":
            in_req = False
            continue
        if line.startswith("require "):
            tokens = line.split()[1:]
            if len(tokens) >= 2:
                out["requires"].append((tokens[0], tokens[1], "indirect" in raw))
            continue
        if in_req:
            tokens = line.split()
            if len(tokens) >= 2:
                out["requires"].append((tokens[0], tokens[1], "indirect" in raw))
    return out


def module_to_node(mod_path: str, name_map: dict[str, str]) -> str | None:
    """Translate a Go import path into a node name. Returns None if
    the path is not a Pilot Protocol module."""
    prefix = "github.com/pilot-protocol/"
    if mod_path.startswith(prefix):
        top = mod_path[len(prefix):].split("/", 1)[0]
        return name_map.get(top)
    return None


def production_imports_hub(owner: str, repo: str, ref: str, candidate_files: list[str]) -> bool:
    """Best-effort heuristic: does any candidate prod file actually
    import a hub path? Used to drop the test-only edge cycle-back
    to the hub."""
    hub_paths = ("github.com/pilot-protocol/pilotprotocol", "github.com/pilot-protocol/web4")
    for fp in candidate_files:
        src = fetch_file(owner, repo, ref, fp)
        if src and any(p in src for p in hub_paths):
            return True
    return False


def build_graph(org: str, hub: str, policy: dict) -> tuple[dict[str, list[str]], dict[str, dict]]:
    """Returns (adj, node_meta).
      adj[name] = list of upstream nodes `name` depends on
      node_meta[name] = {repo, zone, bump_policy}
    """
    print(f"# Listing repos in {org}...", file=sys.stderr)
    org_repos = list_org_repos(org)
    names = [r["name"] for r in org_repos]
    name_map = {n: n for n in names}

    hub_owner, hub_repo = hub.split("/", 1)
    # H4: the hub repo (pilot-protocol/pilotprotocol) is the single node
    # "web4". Alias its module path to that node so a sibling requiring
    # github.com/pilot-protocol/pilotprotocol resolves to "web4" — not to
    # a second, policy-less "pilotprotocol" node that the org walk would
    # otherwise create (zone-1/auto), double-dispatching the same repo.
    name_map[hub_repo] = "web4"

    adj: dict[str, list[str]] = {}
    node_meta: dict[str, dict] = {}

    def meta_for(name: str, repo: str, zone_default: int, *, dispatchable: bool) -> dict:
        sidecar = policy.get("nodes", {}).get(name, {})
        return {
            "repo": repo,
            "zone": sidecar.get("zone", zone_default),
            "stable_only": sidecar.get("bump_policy", {}).get("stable_only", True),
            "mode": sidecar.get("bump_policy", {}).get("mode", "auto"),
            "dispatchable": dispatchable,
        }

    def edges_from(text: str, self_name: str) -> list[str]:
        out = []
        for path, _, _indirect in parse_go_mod(text)["requires"]:
            node = module_to_node(path, name_map)
            if node and node != self_name:
                out.append(node)
        return out

    # Walk each org repo
    for r in org_repos:
        name = r["name"]
        # The hub is handled explicitly below as node "web4"; skip its
        # repo here so it does not also become a duplicate "pilotprotocol".
        if name == hub_repo:
            continue
        ref = (r.get("defaultBranchRef") or {}).get("name") or "main"

        gomod = fetch_file(org, name, ref, "go.mod")
        # Nested submodules (examples/go/go.mod, app-store/integration/go.mod).
        # Probed even when there is NO root go.mod — else a repo whose only
        # module is nested (examples) was dropped from the graph entirely.
        nested_mods = []
        for sub in ("integration/go.mod", "go/go.mod"):
            nested = fetch_file(org, name, ref, sub)
            if nested:
                nested_mods.append(nested)

        # Skip repos with no Go module at all that aren't manual nodes.
        if not gomod and not nested_mods and name not in policy.get("manual_nodes", {}):
            continue

        edges = []
        if gomod:
            edges += edges_from(gomod, name)
        for nm in nested_mods:
            edges += edges_from(nm, name)

        # Cycle-back guard: drop the web4 edge if no prod file imports
        # the hub directly (the require is test- or transitive-only).
        if "web4" in edges:
            if not production_imports_hub(
                org, name, ref,
                ["handshake.go", "runtime.go", "embedded.go",
                 "service.go", f"{name}.go", "main.go"],
            ):
                edges = [e for e in edges if e != "web4"]

        # SDKs have an implicit build-time edge to libpilot that no
        # manifest captures. (They self-poll rather than receive a
        # dispatch, so the dispatchable check below excludes them as
        # targets — the edge only keeps their depth honest.)
        if name in ("sdk-node", "sdk-python", "sdk-swift"):
            edges.append("libpilot")

        adj[name] = sorted(set(edges))
        node_meta[name] = meta_for(
            name, f"{org}/{name}", zone_default=_default_zone_for(name),
            dispatchable=has_cascade_receiver(org, name, ref),
        )

    # Hub itself → the single "web4" node.
    hub_gomod = fetch_file(hub_owner, hub_repo, "main", "go.mod")
    if hub_gomod:
        adj["web4"] = sorted(set(edges_from(hub_gomod, "web4")))
        node_meta["web4"] = meta_for(
            "web4", hub, zone_default=2,
            dispatchable=has_cascade_receiver(hub_owner, hub_repo, "main"),
        )

    # Manual nodes (homebrew, website, freeloaders). mode=="poll" nodes
    # self-update and are skipped by the orchestrator fan-out; keep them
    # in the graph for depth honesty but mark non-dispatchable.
    for name, manual in policy.get("manual_nodes", {}).items():
        if name in adj:
            continue
        adj[name] = sorted(manual.get("depends_on", []))
        node_meta[name] = meta_for(
            name, manual["repo"], zone_default=_default_zone_for(name),
            dispatchable=False,
        )

    return adj, node_meta


def _default_zone_for(name: str) -> int:
    if name == "web4":
        return 2
    if name in ("sdk-node", "sdk-python", "sdk-swift", "homebrew-pilot"):
        return 3
    if name in ("website",):
        return 4
    if name in ("cosift", "pilot-ca", "wallet"):
        return 0
    return 1


def reverse_closure(adj: dict[str, list[str]], root: str) -> list[tuple[str, int]]:
    """Return [(node, depth), ...] sorted by depth then name."""
    children = defaultdict(list)
    for node, deps in adj.items():
        for dep in deps:
            children[dep].append(node)
    depth = {root: 0}
    q = deque([root])
    while q:
        n = q.popleft()
        for c in children.get(n, []):
            if c not in depth:
                depth[c] = depth[n] + 1
                q.append(c)
    depth.pop(root, None)
    result = sorted(((n, d) for n, d in depth.items()), key=lambda x: (x[1], x[0]))
    # PILOT-316: explicit defense-in-depth — root must never appear in the
    # closure (it should have been removed by depth.pop above). If a
    # future graph-construction bug introduces a back-edge to root, the
    # BFS could re-add it and we'd cascade a release into itself.
    assert root not in (n for n, _ in result), \
        f"self-cascade: closure for {root!r} contains itself — graph has a back-edge"
    return result


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--package", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--is-prerelease", default="false")
    ap.add_argument("--policy", default="policy.json")
    ap.add_argument("--output", default="-")
    ap.add_argument("--org", default="pilot-protocol")
    ap.add_argument("--hub", default="pilot-protocol/pilotprotocol")
    args = ap.parse_args()

    policy = {}
    if Path(args.policy).exists():
        policy = json.loads(Path(args.policy).read_text())

    adj, node_meta = build_graph(args.org, args.hub, policy)

    if args.package not in adj and args.package not in node_meta:
        print(f"::error::package '{args.package}' not in graph", file=sys.stderr)
        return 1

    closure = reverse_closure(adj, args.package)

    is_pre = args.is_prerelease.lower() == "true"

    targets = []
    skipped = []
    for node, depth in closure:
        meta = node_meta.get(node, {})
        # Filter out beta dispatches to stable_only nodes here too —
        # belt-and-braces with the receiver's own gate.
        if is_pre and meta.get("stable_only", True):
            skipped.append((node, "beta→stable_only"))
            continue
        # Zone-0 nodes are freeloaders — explicitly not in the cascade.
        if meta.get("zone", 1) == 0:
            skipped.append((node, "zone-0"))
            continue
        # A node with no cascade.yml cannot receive a bump-upstream
        # dispatch; including it produced a phantom ✓ (204/403 no-op)
        # that masked real coverage. Log it rather than silently drop.
        if not meta.get("dispatchable", True):
            skipped.append((node, "no-cascade-receiver"))
            continue
        targets.append({
            "node": node,
            "repo": meta.get("repo", f"pilot-protocol/{node}"),
            "depth": depth,
            "zone": meta.get("zone", 1),
            "stable_only": meta.get("stable_only", True),
            "mode": meta.get("mode", "auto"),
        })

    for node, why in skipped:
        print(f"# skipped {node}: {why}", file=sys.stderr)

    out = {
        "upstream": args.package,
        "version": args.version,
        "is_prerelease": is_pre,
        "targets": targets,
    }

    text = json.dumps(out, indent=2)
    if args.output == "-":
        print(text)
    else:
        Path(args.output).write_text(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
