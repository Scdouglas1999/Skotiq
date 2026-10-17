# Running a sweep workflow without losing agents

Written after the first full sweep (`wf_7cfdb3c5-1fd`), in which **3 of 11 agents died mid-run** and
several more were cut short. None of the failures were the app's fault, and none were random. All
four causes below are structural, and all four are now designed out.

## What actually happened

| agent | images read | transcript | outcome |
|---|---|---|---|
| sky-wizards | 124 | 29.1 MB | interrupted |
| imaging-guiding | 116 | 28.1 MB | `API Error: Connection closed mid-response` |
| settings-core | 108 | 15.8 MB | `API Error: Connection closed mid-response` |
| analytics-science | 87 | 12.4 MB | `API Error` — **after** finishing the sweep and stopping its app |
| settings-imaging | 54 | 9.9 MB | `[Request interrupted]` at screenshot 55 of 98 |

The ordering is the finding: **the biggest transcripts are the ones that died.** Across the whole
run, agents produced 2,622 screenshots totalling 366 MB, nearly all 1920x1200.

## Cause 1 — screenshots dominate context

A 1920x1200 capture costs on the order of **2000 tokens** encoded. At 130 images that is ~250k
tokens spent on pictures before any tool output, source reading or reasoning. Agents in that state
emit truncated responses and drop connections.

**Fixed in the harness.** `drive_linux.py shot` now crops to the app window (the window is 1600x900
inside a 1920x1200 root, so ~40% of every old capture was black margin) and downscales to 1280px
wide. `--region WxH+X+Y` captures a single panel for less again; `--raw` is still there for the rare
case where full resolution is the evidence.

**Fixed in the brief.** Agents are now told to check state with `tree` — which is *text*, and
answers "what is on screen / what is this control called / is it on, off or disabled" better than a
picture — and to screenshot only when the question is about layout or rendering. And to capture
liberally but `Read` selectively: taking a screenshot is free, reading it is the cost.

## Cause 2 — the report was held to the end, so dying cost everything

`analytics-science` completed its entire sweep, cleanly stopped its app, said *"App stopped. Here is
my report"* — and died emitting the structured result. All of that work was lost at the last step,
and its transcript contains no prose to recover it from, because the findings only ever existed in
the final message.

**Fixed by making the work durable as it is produced.** Sweep agents now append each confirmed
finding to `reports/coverage/swept/<area>.json` as they go. An agent that dies at any point still
leaves everything it had confirmed up to that moment.

**Fixed by collecting from disk, not from return values.** A workflow script cannot read files
itself, so the pipeline ends with a small **collector agent** that reads
`reports/coverage/swept/*.json` and returns the merged result. A dropped final response now costs
one agent's last few findings instead of its whole run:

```js
phase('Collect')
const merged = await agent(
  `Read every file in reports/coverage/swept/. Merge them, drop exact duplicates, and return the
   combined result. Some files are from agents that died mid-run and may be truncated or have a
   trailing comma — repair what you can and REPORT which files were incomplete rather than
   silently dropping them.`,
  { label: 'collect', phase: 'Collect', schema: MERGED_SCHEMA },
)
```

## Cause 3 — scopes were too big to finish inside one context

`planning` ran to 1047 turns; several agents were still going after an hour. An agent that cannot
finish its checklist within its context will always fail near the end, which is the worst place.

**Fix:** size a slice at roughly **15-25 ledger units**, not a whole product area. `settings` (69
units) needed three agents and still ran long; `sequencer` (126 units) needs four or five, not
three. Check the unit counts in `reports/coverage/units_by_area.json` before assigning, and prefer
more agents with smaller slices — they run concurrently anyway, so it costs wall-clock nothing.

## Cause 4 — display collisions

Two agents were assigned displays that a **previous session's** abandoned instance still held, so
their screenshots captured a different process's app — one showing plausible observing data that
would have been reported as this run's findings.

**Fixed in the harness.** `start` now refuses a display that already has windows, and the
accessibility root is matched by **process id**, never by application name (the AT-SPI registry is
per login session, not per display, so name matching can pick up the developer's own running app —
and a `click` would then drive it).

**Still required of the caller:** assign each agent its own `SK_AUDIT_DISPLAY`, and check the
display is free first:

```bash
for d in $(seq 81 99); do echo ":$d $(DISPLAY=:$d xdotool search --onlyvisible --name . 2>/dev/null | wc -l)"; done
```

## Checklist for the next sweep workflow

- [ ] Each agent gets its own `SK_AUDIT_DISPLAY`, verified free before launch.
- [ ] Slices of ~15-25 ledger units, taken from `units_by_area.json`.
- [ ] Brief includes the context-budget rules (`tree` over `shot`; capture liberally, read selectively).
- [ ] Brief requires incremental writes to `reports/coverage/swept/<area>.json`.
- [ ] Pipeline ends with a collector agent that merges from disk.
- [ ] Agents told not to run `flutter build` / `cargo build` — concurrent builds corrupt every
      running instance, including their own.
