# AGENTS.md — Skotiq

Persistent working instructions for agents in this repo.

## Codebase navigation

This project keeps a knowledge graph at `graphify-out/` (see also `CLAUDE.md`).
Use the graph for architecture and relationship questions when it is relevant
and current. Use targeted source reads and `rg` for exact symbols, literal
strings, and small edits; verify graph findings against source before changing code.

For broad "how do A and B relate" or "what calls/uses this" questions,
`graphify` can identify a useful starting set of files. Choose direct search
when the question is already narrow or the graph does not surface enough.

Commands (run from repo root; `graph.json` defaults to `graphify-out/graph.json`):

- `graphify query "<question>"` — BFS traversal for a question. Add `--budget N`
  to cap tokens, `--context <edge>` (e.g. `--context call`) to narrow.
- `graphify path "<A>" "<B>"` — shortest path / relationship between two nodes.
- `graphify explain "<concept>"` — focused plain-language explanation of a node + neighbors.
- `graphify affected "<X>"` — reverse traversal: what is impacted by X.
- Navigation: `graphify-out/wiki/index.md` for broad maps; `graphify-out/GRAPH_REPORT.md`
  only for full architecture review.

When the task includes graph maintenance, or changed relationships make a graph
you are actively using stale, refresh it with `graphify update .` (AST-only).
An absent or stale graph does not block ordinary source work. Do not rebuild
the graph for unrelated edits or documentation-only changes.
