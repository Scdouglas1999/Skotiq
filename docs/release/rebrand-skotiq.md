# Skotiq — a new name

This release renames the app. The name it shipped under before belonged to
someone else's product, so it had to change. It is now called Skotiq, after
scotopic vision — from the Greek *skotos*, "darkness" — the rod-based vision
the eye switches to in the dark, which is the state the app is built around.

Nothing about how it works changes in this release. The features are the same;
the name, the artwork and the identifiers underneath are new.

## What changes on your machines

The app is now Skotiq everywhere it used to carry the old name: the title bar,
the about screen, the icon, the desktop entry and the documentation.

- On Windows the program is `skotiq_desktop.exe`, and a fresh install goes to
  `%LOCALAPPDATA%\Programs\Skotiq`. The portable zip still runs from wherever
  you extract it.
- On Linux the binary and data folders use the new name; the launcher is still
  `skotiq`.
- The desktop and mobile application ids are now `com.skotiq.desktop` and
  `com.skotiq.mobile`, and the mDNS service advertises as `_skotiq._tcp`.
- Environment variables and config keys that carried the old name are now
  `SKOTIQ_*`. If you run the headless host under systemd or a wrapper script
  that sets them, update the unit or script to match.

## Your data moves itself

The first time the new build runs, it moves an existing install's data across
automatically — settings, equipment profiles, sequences, targets and history.
There is nothing to export or copy by hand; launch the new build and your setup
is where you left it.

## Android is a fresh install

Android identifies apps by their application id, so the companion app's new
`com.skotiq.mobile` id makes it a different app as far as the phone is
concerned. There is no upgrade path between the two:

1. Install the new Skotiq APK alongside the old one.
2. Bring your pairing across — either export the profile from the old app and
   re-import it, or pair the new app with the host again. Pairing takes a
   minute from the host's Remote access screen.
3. Check the new app connects, then uninstall the old one.

Push-notification and background-refresh settings are per app, so review them
once in the new app after it is paired.

## If something does not move

Keep the old install until the new build has opened your profile once. If a
data folder does not come across, the migration guide in
`docs/migration-backup-restore.md` covers restoring from a `.nsbackup`, and the
troubleshooting guide lists the data locations on each platform.
