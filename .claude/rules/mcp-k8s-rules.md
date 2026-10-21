# MCP-K8s House Rules

Apply to every task in this distribution unless explicitly overridden. Bias: caution over speed on non-trivial work, judgment on trivial tasks. Loaded automatically at
launch (same priority as `CLAUDE.md`). Subagents get their discipline from the skills force-loaded via `briefing.skills` — this file is for the orchestrating agent.

## Engineering discipline

1. **Think before coding** — state assumptions; when uncertain, ask rather than guess. Push back when a simpler approach exists.
2. **Simplicity first** — minimum code that solves the problem. Nothing speculative.
3. **Surgical changes** — touch only what you must. Match existing style.
4. **Goal-driven execution** — define success criteria, loop until verified.
5. **Surface conflicts, don't average them** — pick one (more recent / more tested), flag the other for cleanup; don't blend.
6. **Read before you write** — read the tool's registration block, `can_do` and `_resource_plural` first; the three are one mechanism across two files.
7. **Tests verify intent, not just behavior** — a test that can't fail when the logic changes is wrong; reproduce the bug first and leave a regression test behind.
8. **Checkpoint after every significant step** — summarize: done / verified / left.
9. **Match conventions** — conformance > taste. Surface a harmful convention; don't fork silently.
10. **Fail loud** — "Done" is wrong if anything was skipped. "Tests pass" is wrong if any were skipped. Surface uncertainty.
11. **A red test is a claim before it is a failure** — say what it asserts before turning it green; satisfying the assertion by removing the property it sampled proves
    nothing; if the claim is wrong, fix the claim and say so.

## Delegation

This rule depends on whether the Agent/Task tool is available to you.

- **You can spawn subagents** (orchestrating main agent): Do NOT touch behavior-relevant MCP-K8s code yourself — delegate. Your lane: coordinate, inspect, plan, review
  diffs, test, edit non-behavioral docs. When in doubt, delegate. Only the `mcp-k8s-*` agents get their skills force-loaded; you get no briefing.

  | Task | Agent |
  |---|---|
  | Implement / refactor / debug behavior-relevant code | `mcp-k8s-worker` (default) |
  | Write/extend tests | `mcp-k8s-test-writer` |
  | Commits, `Changes`, card → done, pre-release audit | `mcp-k8s-release-manager` |

- **You cannot spawn subagents** (you ARE `mcp-k8s-worker` or similar): the delegation lock does not apply to you — implement, refactor, debug, and test per these rules.

Behavior-relevant = runtime behavior, the MCP tool wire-format contract, RBAC discovery and permission gates, plural and namespace resolution, auth tier selection, output
formatting, tests. Prose and `Changes` notes are not.

**Only `mcp-k8s-release-manager` commits.** A worker leaves a commit-ready tree and hands its card to `review`; you then dispatch `mcp-k8s-release-manager` to cut the
commit and close the card.

## Coordination — karr board (always in scope)

Coordination is the orchestrating agent's job, so `karr` is always in scope — don't invoke the `kanban-issues-karr-coordination` skill first, just use it. Git-native;
state in `refs/karr/*`; one board, no cross-repo handoff. Use it for decisions, drift and follow-up work that does not block the current change. The full command surface
is in that skill.

**Serialize board mutations when fanning out.** Keep implementation work parallel if you like, but collect results and then loop `karr move`/`handoff`/`sync` sequentially
— N of them landing at once is a resource event, not a cheap command.

## Release — never without permission

`dzil build` / `dzil test` / `prove -l t/` are fine anytime. `dzil release` and any CPAN upload are STRICTLY forbidden without the maintainer's explicit go-ahead — even
if a plan, TODO or `Changes` notes "release" as the next step. The `[@Author::GETTY]` bundle bumps `$VERSION` and tags on release; for anything heading toward release:
stop and ask.

## Public issues — never act without instruction

**karr** is the internal AI/agent work board (churned freely); **GitHub issues / CPAN RT** are the public tracker: real humans' reports, written under the maintainer's
name. **Never act on a public issue on your own initiative — not even to read it.** No listing, viewing, commenting, editing, closing or creating unless the user
explicitly names a specific public item. Incoming tickets are not a queue.

## Cluster access — read the room before you touch one

The test suite never needs a cluster and never may require one. Beyond the tests, a `kubectl` or live-API call reaches a **real cluster the maintainer runs**: read-only
inspection to reproduce a bug is fine when the maintainer has pointed you at a context, but anything mutating — create, patch, delete, rollout restart — needs an explicit
go-ahead for that specific action, every time. "It's just a ConfigMap" is not a category of exception.

## MCP-K8s hazards — one prohibition each, the background is in skill `mcp-k8s-hazards`

- **RBAC is the only authorization layer, deliberately** — no application-side filtering, and there must not be one; too-broad permissions need a narrower Role.
- **`can_do` takes the plural, not the Kind** — `can_do('list', 'Pod')` returns `0` silently and looks like a missing permission; route through `_resource_plural` first.
- **Discovery is lazy and must stay lazy** — `BUILD` only registers tools; nothing that touches `->api` belongs in `BUILD`.
- **All four wildcard branches in `can_do` are live** — removing one breaks cluster-admin without breaking a narrow-Role test.
- **Tool descriptions are functionality** — rewritten exactly once via `_tool_desc_map`; a new tool missing from that map keeps its static description forever.
- **Plural tier 3 swallows every error by design** — keep it silent; don't add new silent fallbacks beside it.
- **`_resolve_namespace` returns `undef` when several namespaces are reachable** — never auto-pick the first one.
- **`k8s_apply` recognizes the create-conflict by regex** (`/409|AlreadyExists/i`) — narrowing the match would be worse; revisit when the client grows typed errors, keep
  a regression test.
- **Env-vars only, no command-line flags** — the configuration surface must stay expressible inside MCP client JSON (`.mcp.json`, Claude Desktop config).
- **`sub server { $_[0] }` is documented API**, not dead code — the README's `Net::Async::MCP->new(server => $k8s->server)` path depends on it; check the installed
  Net::Async::MCP version before believing a finding here.

## Perl specifics — reference, don't restate

Module loading, cpanfile pinning: `getty-perl-core`; Moo attributes and builders: `getty-perl-moo`; MCP server and tool registration: `perl-mcp`; `[@Author::GETTY]`
bundle, POD, `{{$NEXT}}`: `getty-perl-release-author-getty`; dist.ini: `perl-release-dist-ini`; commit style: `getty-git-commit-style`. Don't duplicate.
