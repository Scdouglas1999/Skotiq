# Sequence fixtures for live UI checks

Load through Sequencer › canvas bar › More actions › Open sequence (the GTK
chooser on the harness display accepts `ctrl+l` + a typed path; see the
memory note in the harness README).

- `full-night.skeq.json` — two targets (NGC 7000 narrowband ×12, M31 LRGB ×20),
  setup, triggers, shutdown: 36 visible nodes. The ledger density redesign was
  verified against this night. Requires `Ha`, `OIII`, `SII` in the active
  equipment profile's filter list or the import validator refuses it.
- `sim-run-short.skeq.json` — a one-minute simulator run (unpark, slew,
  2 × L/R/G at 2 s, park) for exercising running-state UI. Move the site
  longitude to a night meridian first; the executor refuses on-sky work in
  daylight.
