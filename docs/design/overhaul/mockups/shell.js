// Injects the shared shell (top bar, rail, instrument bar) so every mockup page
// renders the same chrome. Pages opt in with:
//   <body data-selected="tonight" data-rail="collapsed|expanded" data-devices="none|connected" data-run="idle|ready|running">
// The rail list below IS the navigation spec (04-shell.md §2).

const RAIL = [
  { group: "Observe" },
  { id: "tonight",   icon: "moon-star",        label: "Tonight" },
  { id: "imaging",   icon: "camera",           label: "Imaging" },
  { id: "sequencer", icon: "list-ordered",     label: "Sequencer" },
  { id: "guiding",   icon: "crosshair",        label: "Guiding" },
  { group: "Prepare" },
  { id: "plan",      icon: "compass",          label: "Plan" },
  { id: "equipment", icon: "plug",             label: "Equipment" },
  { id: "weather",   icon: "cloud-sun",        label: "Weather" },
  { group: "Review" },
  { id: "darkroom",  icon: "aperture",         label: "Darkroom" },
  { id: "analytics", icon: "bar-chart-3",      label: "Analytics" },
];

function icon(name, extra = "") { return `<span class="i i-${name} ${extra}"></span>`; }

function topbar() {
  return `
  <header class="topbar">
    <div class="brand">${'<span class="mark">' + icon("sparkles") + '</span>'}<span class="word">SKOTIQ</span></div>
    <div class="cmd">${icon("search")}<span>Search targets, settings, or jump to a screen</span><span class="kbd">Ctrl K</span></div>
    <div class="right">
      <span class="iconbtn" title="Remote: local">${icon("monitor")}</span>
      <span class="iconbtn" title="Alerts">${icon("bell")}</span>
      <span class="iconbtn" title="Help for this screen">${icon("help-circle")}</span>
      <span class="iconbtn" title="Settings">${icon("settings")}</span>
      <span class="win"><span class="iconbtn">${icon("minus")}</span><span class="iconbtn">${icon("square")}</span><span class="iconbtn">${icon("x")}</span></span>
    </div>
  </header>`;
}

function rail(selected, expanded) {
  const items = RAIL.map((r) => {
    if (r.group) return `<div class="group-label eyebrow">${r.group}</div>${expanded ? "" : '<div class="gap"></div>'}`;
    const sel = r.id === selected ? " selected" : "";
    const badge = r.id === "equipment" && document.body.dataset.devices === "none" ? '<span class="badge"></span>' : "";
    return `<a class="item${sel}" title="${r.label}">${icon(r.icon)}<span class="label">${r.label}</span>${badge}</a>`;
  }).join("");
  // Remove the leading gap that the first group would otherwise produce.
  const cleaned = items.replace('<div class="gap"></div>', "");
  return `<nav class="rail">${cleaned}<div class="spacer"></div>
    <a class="item" title="${expanded ? "Collapse" : "Expand"} navigation">${icon(expanded ? "panel-left-close" : "panel-left")}<span class="label">Collapse</span></a>
  </nav>`;
}

function instrument() {
  const d = document.body.dataset;
  const run = d.run || "idle";
  const connected = d.devices === "connected";
  const runChip = { idle: ["", "Idle"], ready: ["acc", "Ready"], running: ["ok live", "Running"] }[run];
  const dev = (name, value, state) => `<span class="pill">${icon(name)}<span class="dot ${state}"></span><b>${value}</b></span>`;
  return `
  <footer class="instrument">
    <span class="pill"><span class="dot ${runChip[0]}"></span><b>${runChip[1]}</b></span>
    <span class="sep"></span>
    ${connected
      ? dev("camera", "ASI2600MM", "ok") + dev("mountain", "EQ6-R", "ok") + dev("crosshair", "PHD2", "") + dev("focus", "EAF 25000", "ok") + dev("disc", "Ha", "ok")
      : dev("camera", "No camera", "") + dev("mountain", "No mount", "") + dev("crosshair", "No guider", "") + dev("focus", "No focuser", "")}
    <span class="right">
      ${connected ? `<span class="pill">${icon("thermometer")}<b>-10.0°C</b></span>` : ""}
      <span class="pill">${icon("hard-drive")}<b>${connected ? "D:\\Captures · 412 GB free" : "No save folder"}</b></span>
      <span class="sep"></span>
      <span class="pill">${icon("clock")}<span class="clock">22:41:08</span><span class="muted">LST</span><span class="clock">03:12:44</span></span>
    </span>
  </footer>`;
}

document.addEventListener("DOMContentLoaded", () => {
  const body = document.body;
  const expanded = body.dataset.rail === "expanded";
  const app = document.querySelector(".app");
  if (expanded) app.classList.add("rail-expanded");
  app.insertAdjacentHTML("afterbegin", topbar() + rail(body.dataset.selected, expanded));
  app.insertAdjacentHTML("beforeend", instrument());
});
