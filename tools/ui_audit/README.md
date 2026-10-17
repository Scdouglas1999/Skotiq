# Driving the app for an audit (Linux)

`drive_linux.py` launches a sandboxed Skotiq instance on a private X server
and lets you read and operate it. Everything below was learned by getting it
wrong first; none of it is optional.

## Quick start

```bash
cd apps/desktop && flutter build linux --release      # once
python3 tools/ui_audit/drive_linux.py start --fresh   # --fresh wipes the scratch profile
python3 tools/ui_audit/drive_linux.py shot /tmp/sk-audit/shots/a.png   # cropped + downscaled
python3 tools/ui_audit/drive_linux.py shot --region 800x400+560+300 out.png  # one panel
python3 tools/ui_audit/drive_linux.py shot --raw out.png              # full-res, rarely needed
python3 tools/ui_audit/drive_linux.py tree            # live widget names + states
python3 tools/ui_audit/drive_linux.py click-img shot.png 990 34   # coords AS MEASURED IN shot.png
python3 tools/ui_audit/drive_linux.py click-xy 1440 1010          # raw root coords
python3 tools/ui_audit/drive_linux.py key Escape
python3 tools/ui_audit/drive_linux.py type "M31"
python3 tools/ui_audit/drive_linux.py log --tail 100
python3 tools/ui_audit/drive_linux.py stop
```

Use `--profile NAME` to run more than one instance. Each profile gets its own
display-sharing app process, scratch database and log, but they all share one
Xvfb display, so **two profiles will click on each other's windows**. For real
isolation, set `SK_AUDIT_DISPLAY` to a different display per agent.

## Context budget — the thing that actually kills sweep agents

In the first full sweep, **3 of 11 agents died mid-run** and several more were cut short. The cause
was not the app and not the harness logic: it was screenshots. Agents had read **116-140** full-size
captures each, and the three largest transcripts (28-29 MB) are exactly the agents that failed.

A 1920x1200 screenshot costs on the order of **2000 tokens** once encoded. 130 of them is ~250k
tokens of context spent on images alone, before a single line of tool output or reasoning. An agent
in that state produces truncated responses and dropped connections, and — worst of all — it usually
dies **while emitting its final report**, so a complete sweep is lost at the last step.

Three rules follow, in order of how much they save:

1. **Read `tree`, not `shot`, to check state.** The accessibility tree is text and nearly free, and
   it answers most audit questions better than a picture does: what is on screen, what each control
   is called, whether it is on, off, disabled or missing. Screenshot when the question is about
   *layout or rendering* — overlap, truncation, alignment, colour. Do not screenshot to find out
   whether a toggle flipped.
2. **Capture liberally, `Read` selectively.** Taking a screenshot costs nothing; reading it into
   context is the expense. Capture as you go for evidence you can cite by path in your report, and
   only open the ones you actually need to look at.
3. **Let `shot` shrink it.** It now crops to the app window and downscales to 1280px wide by
   default, which is ~40% cheaper than a raw root capture and still legible for every label in this
   UI. `--region WxH+X+Y` for a single panel is cheaper again. `--raw` is available when
   pixel-exact full-resolution evidence is genuinely the point — it rarely is.

**Write your findings to a file as you go.** Do not hold a whole sweep's results in your head to
emit at the end; that is precisely when a context-heavy agent dies. Append to
`reports/coverage/swept/<area>.json` as you confirm each one, so an interrupted run still leaves its
work behind.

## The traps

**Bind to the pid, never the app name.** The AT-SPI registry is per login
session, not per X display, so the developer's own Skotiq — running on their
real desktop against their real observing database — appears in the same
enumeration as the sandbox. Selecting the accessibility root by name picked up
the wrong process, and a click would have driven their live session. `tree` and
`click` match `app.pid` for this reason.

**`tree` gives names, roles and states; it does not give geometry.** This
build's AT-SPI bridge answers `get_name`/`get_role_name`/`get_state_set` but
times out on the Component interface, so there are no coordinates to click.
Workflow: `shot`, read the image, then **`click-img <that shot> X Y`**.
`click <name>` exists only to tell you whether a control is present and whether
it is enabled or checked.

**Use `click-img`, not `click-xy`, for anything you measured in a screenshot.**
Because `shot` crops to the window and downscales, image coordinates are no
longer root coordinates — on this layout they are off by (160,150) and a factor
of 1.25, so a `click-xy` with numbers read off a screenshot lands on a different
control and the sweep reports that control's behaviour under the wrong name.
`shot` writes a `.coords.json` beside every capture and `click-img` applies it.
`click-xy` remains correct for coordinates you got some other way.

**States are the point.** `tree` annotates `[ON]` / `[off]` for checkables,
`[DISABLED]` for dead interactive controls and `[offscreen]`. Auditing "every
switch" means reading these, not just seeing that a row rendered.

**The scratch profile is real.** `SKOTIQ_DATABASE_DIR` and
`SKOTIQ_DATA_DIR` point into `/tmp/sk-audit/<profile>/data`, so a sweep never
touches real observing data — but it also means a fresh profile starts at
onboarding step 1 every time, and any state a test depends on must be set up
first.

**Rendering is softpipe, not llvmpipe.** Under Mesa 26 llvmpipe does not survive
this app's startup on a virtual display. Softpipe is slow — expect a second or
two of settle time after every interaction before screenshotting.

**The app takes a single-instance lock.** A second launch of the same profile
exits silently, which looks exactly like a crash. `start` refuses when one is
already up rather than leaving you to diagnose it.
