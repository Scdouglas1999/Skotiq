# r4-docs — rebrand report

Scope: every `*.md` file, the `docs/` and `reports/` trees, `README.md`,
`AGENTS.md`, `LICENSE`, `.github/*.md`, `.github/ISSUE_TEMPLATE/`.

Worktree checked out at `0f14e3843` on branch `rebrand/skotiq-r4-docs`.

## What I changed and why

The mechanical pass left the markdown tree in good shape: zero old-name
mentions (`tools/rebrand/rebrand.py --check`), "Skotiq" used correctly in
prose, `skotiq` only in code/paths/URLs. My work was the residue a
find-and-replace cannot do.

### Fixes

- `docs/getting-started/installation.md` — the Linux data directory was
  `~/.local/share/skotiq/`; the real one is `~/.local/share/skotiq_desktop/`
  (path_provider resolves the support dir from the `skotiq_desktop` binary
  name — matches `docs/RUNBOOK.md`'s canonical table). Fixed; pre-existing
  error that survived the rename.
- `.github/CONTRIBUTING.md` — link to `../README.md#build-from-source` pointed
  at a heading that does not exist; retargeted to `#building-it-yourself`.
- `docs/features/imaging.md` — removed three troubleshooting bullets whose
  targets (`#cooling-problems`, `#poor-tracking`, `#hfr-inconsistent`) never
  existed in `docs/troubleshooting/common-issues.md` (checked history: the
  anchors were dead since the file's first commit, not a rebrand casualty).
  Retargeting would have duplicated existing bullets, so the dead entries were
  removed.

### Additions

- `README.md` — one `> [!NOTE]` under "Getting started": Skotiq was previously
  released under another name, and on first launch it moves an existing
  install's data across automatically. Two sentences, no old product name.
- `docs/getting-started/installation.md` — the same two-sentence note at the
  top of "First launch", where the move actually happens.
- `docs/release/rebrand-skotiq.md` — draft release note for the rebrand
  release, in the `docs/release/v*.md` house style (plain prose sections).
  Covers the name and its scotopic-vision etymology in one sentence, new icons
  and ids (`com.skotiq.desktop`, `com.skotiq.mobile`, `_skotiq._tcp`,
  `SKOTIQ_*`), `skotiq_desktop.exe` / `%LOCALAPPDATA%\Programs\Skotiq` on
  Windows, the automatic data move on first launch, and the Android fresh
  install (new application id means uninstall the old app; profiles export and
  re-import or re-pair).

### New tooling

- `reports/rebrand/check_md_links.py` — markdown link checker used for the
  before/after counts. Checks inline links, reference-style
  definitions and `<img src>` targets; skips fenced code blocks (PowerShell
  snippets contain `[Type]::Method(...)` lookalikes); with `--anchors` it
  resolves `#fragment` links against GitHub-style slugs of the target file's
  headings.

## Verification commands

All run from the worktree root with `TMPDIR=$HOME/.cache/ns-tmp/r4-docs`.

```
git rev-parse HEAD                       # 0f14e3843254697dd3ce3d5385a008f1a5342977
python3 tools/rebrand/rebrand.py --check > /tmp/rebrand_check.log 2>&1; echo EXIT=$?
                                         # EXIT=0 — "0 leftover mention(s)"
python3 reports/rebrand/check_md_links.py --anchors > /tmp/links_before.txt 2>&1; echo EXIT=$?
                                         # EXIT=1 — 4 broken anchors (before)
python3 reports/rebrand/check_md_links.py --anchors > /tmp/links_final.txt 2>&1; echo EXIT=$?
                                         # EXIT=0 — 0 broken (after fixes)
rg -il '<old>' --glob '*.md' .   # EXIT=1 — zero hits
rg -n '\ban Skotiq|\ban SKOTIQ' --glob '*.md' .               # EXIT=1 — zero hits
```

Broken-link counts: **4 before → 0 after.** Before-breakdown: 1 stale anchor
in `.github/CONTRIBUTING.md`, 3 never-existed anchors in
`docs/features/imaging.md`. (The checker initially also flagged 2 false
positives — `[System.IO.File]::WriteAllText(...)` inside a PowerShell fenced
block in `apps/desktop/assets/planetarium/catalogs/README.md`; the script now
skips fenced code.)

## Verified against code (read-only checks, other agents' areas)

- Exe/launcher names: `skotiq_desktop.exe` (Windows `BINARY_NAME`), `./skotiq`
  launcher on Linux, `skotiq.db`, `skotiq_session.checkpoint`,
  `~/Documents/Skotiq/` documents root, `%APPDATA%\Skotiq\` released-build log
  root — docs all match.
- Ids: `com.skotiq.mobile`, `group.com.skotiq.app`, `_skotiq._tcp`,
  `SKOTIQ_*` env vars — every env var named in docs exists in code.
- File formats: `.nsbackup`, `.nsrecipe`, `.nseq.json`, `.nsdt`, `.nst`,
  `ns-soak`/`ns-ota`/`ns-audit` scratch dirs — still the real on-disk names in
  code, so docs keep them. If a code-area agent later renames these formats,
  the docs that mention them are `docs/migration-backup-restore.md`,
  `docs/release/v7.0.0.md`, `docs/CHANGELOG.md`,
  `docs/architecture/ui-theming.md`, `docs/skotiq_5_0_contracts.md`,
  `server/skotiq_hub/README.md`, `tools/catalog_prep/README.md`,
  `tools/ui_audit/README.md`, `tools/ui_audit/fixtures/README.md`,
  `tools/harness/sim_night_soak/README.md`, `tools/ota_rehearsal/README.md`.
- `SKOTIQ-LICENSE.txt` in docs is a real shipped filename — `LICENSE` is copied
  to that name inside release bundles by `tools/ota_rehearsal/build_bundle.sh`.

## Judgment calls

- No name-etymology prose existed to rewrite — the old docs never explained
  the old name, so nothing pun- or story-related survived. The new release
  note carries the one-sentence scotopic-vision explanation instead.
- `AGENTS.md` needed no edits: its only content is `graphify-out/` navigation,
  and those paths do not contain the product name. `CLAUDE.md` is deliberately
  untracked per `.gitignore` ("CLAUDE.md stays UNTRACKED (internal AI/deploy
  notes)"), so the `(see also CLAUDE.md)` pointer refers to a local file, not a
  repo file; left as is.
- The docs' existing prose uses en-GB spellings throughout (catalogue, centre,
  colour, authorised). Mass-converting ~290 files is out of scope for a
  rebrand pass and would fight the owner's established voice; my additions are
  written in neutral/American English. Flagging for the reviewer in case a
  repo-wide pass is wanted separately.
- `docs/design/overhaul/04-shell.md` specifies the wordmark as `SKOTIQ` in all
  caps — that is a rendered-logo spec, not prose; left as is.
- `apps/desktop/README.md` and `apps/mobile/README.md` are still Flutter
  template boilerplate (pre-existing, not rebrand damage); left as is.
- Golden PNGs untouched; no test or code files edited.

## Not finished / open questions

- `docs/release/rebrand-skotiq.md` is a draft: it has no version number or
  build metadata yet, and the Android bullet assumes the new APK ships with
  the `com.skotiq.mobile` id already in place (code areas confirm this).
- Whether the desktop updater on an old-name install can deliver the rebrand
  build is an updater-code question outside my area; the note deliberately
  does not claim in-place updating across the rename.
- `docs/getting-started/installation.md` still describes the official 5.0.0
  artifacts (pre-existing version pinning, not a rebrand issue).
