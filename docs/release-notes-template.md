# Skotiq Release Notes Template

Public release notes describe the finished changes to the app and what users need to do when updating. Use plain prose and organize related changes by the workflow they affect.

Do not include internal performance targets, test counts, benchmark runs, CI job details, commit-by-commit history, reviewer decisions or development experiments. For example, a refresh-rate target discussed during development is not a user-facing release limitation. Keep verification, benchmarks, source provenance and sign-off evidence in a separate [release validation record](release-validation-template.md).

Include a limitation when it changes a user’s decision or action: an unavailable platform, incompatible client version, driver requirement, data migration, or a specific behavior and workaround. Every release also says, in a short "What was not tested" list, what a user would otherwise assume was tested: a night on a real rig, interactive use on each desktop platform, the ARM phone builds, the in-app update from the previous release, and which commit the packages were built from when it is not the tag. Leave an item out only when it was tested, and then say what the test covered. Keep the rest of the evidence in the validation record. Describe measurable performance improvements in terms of the user’s experience without promising an unverified speed or frame rate.

Confirm changes against the previous published release. Do not present an existing feature as new merely because it was refactored or newly documented.

---

# Skotiq [version]

[One short paragraph describing the main changes and who benefits.]

## [Workflow or feature]

[Explain the new behavior or the problem that is now fixed. Use the labels users see in the app. Add another section for each substantial group of changes.]

## What was not tested

- [Physical rig night: not run, or which rig, date and what it covered.]
- [Interactive Windows testing: not done, or what was used.]
- [ARM phone: not run, or which APKs on which phone.]
- [In-app update from the previous release on Windows, Linux and a phone: not done, or what was done.]
- [Build commit: the packages are built from the tag commit `<sha>`; say so if they are not.]

## Updating to [version]

[Required host/client versions, backup or migration steps, changed settings, and any action users must take. Include available downloads and installation constraints when relevant.]

[Link to downloads and the relevant user guides.]
