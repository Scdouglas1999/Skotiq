# Skotiq release notes (operational)

This page covers the operational side of the current release: what it was
built from, how to upgrade and roll back, and what was not tested. The
user-facing notes are in `docs/release/v<version>.md`, which is also the body of
the GitHub release. Platform coverage and limits are in
[`known-limitations.md`](./known-limitations.md). Earlier operational notes:
[7.1.0](./release/v7.1.0-release-notes.md), [5.0.0](./release/v5.0.0-release-notes.md).

## 9.0.0

- Version `9.0.0`, build 37, channel `stable`; previous release 8.2.1.
- Tag `v9.0.0` is commit `737546bb8`. The published packages were built from
  `4736791e42ae073dc2ff9874323035051a350206` by release run
  [43620240119](https://github.com/Scdouglas1999/Skotiq/actions/runs/43620240119),
  a build-only run whose assets were attached to the draft by hand. The commits
  between the two change documentation and test code only, so the application
  code in the packages is the tag's. `SOURCE-COMMIT.txt` in every archive names
  `4736791e4`.
- The release was published from a branch that was not merged to `main`, with
  the required CI checks red. From 9.0.1 the release workflow refuses both (see
  `docs/branch-protection.md` section 3).
- Upgrade the imaging host and every linked client together. Back up the
  profile first; the database moves to schema 70 and an older app cannot open
  it. To roll back, restore that backup into the older app.

### What was not tested

- No physical rig night. 9.0.0 was not run on a real mount, camera, focuser or
  guider under the sky; earlier rig nights do not cover this release.
- No interactive Windows testing. CI ran the Windows package against
  simulators (sign-in, WebSocket, a simulator exposure and its FITS file); no
  one used it on a Windows desktop.
- No ARM phone. The arm64-v8a and armeabi-v7a APKs were built and their
  signatures checked, but they were not run on a phone. Only the x86_64 APK was
  run, in an Android 15 emulator.
- No in-app update from an installed 8.2.1 was carried out on Windows, Linux
  or a phone. The signed manifests verify and an 8.2.1 install is offered
  9.0.0, but the download, swap and restart were not exercised end to end.
- The packages were built from `4736791e4`, not from the tag commit.

## The next release

Each release adds a section above in the same shape, and its public notes
(`docs/release/v<version>.md`, the GitHub release body) end with the same
"What was not tested" list, following
[`release-notes-template.md`](./release-notes-template.md). For 9.0.1 that
means stating, in plain words, whether a rig night, interactive Windows use, an
ARM phone and the in-app update from 9.0.0 were tested, and that the packages
were built from the tag commit (the release workflow now refuses anything
else).
