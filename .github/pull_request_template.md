## Summary

<!-- What does this PR change and why? Link issues with "Fixes #123" when applicable. -->

## Type of change

- [ ] Bug fix
- [ ] Feature
- [ ] Refactor / cleanup
- [ ] Docs only
- [ ] Build / CI
- [ ] Generated code (FRB, freezed, drift, etc.)

## Checklist

- [ ] `melos run analyze` passes locally (or `melos run analyze:production` for release-touching work)
- [ ] `melos run test` passes for affected packages
- [ ] Rust changes: `cargo test --all-features` and `cargo clippy --all-features -- -D warnings` in `native/skotiq_native`
- [ ] Rust/API changes: ran `melos run dev` or `melos run generate` so FFI bindings stay in sync
- [ ] No new stubs, silent fallbacks, or placeholder markers (see [CONTRIBUTING.md](CONTRIBUTING.md))
- [ ] Generated-code commits are separate and titled `chore: regenerate generated code` when applicable

## Screenshots / recordings

<!-- UI changes: before/after screenshots or a short screen recording. -->

## Notes for reviewers

<!-- Optional: risky areas, manual test steps, follow-ups. -->
