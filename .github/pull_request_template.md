<!--
Title: a Conventional Commit, e.g. "fix(app): keep the popover open after Install…".
It becomes the commit on dev and decides the next version (feat → minor, fix/perf → patch,
docs/ci/chore → none). See CONTRIBUTING.md.
-->

## What and why

<!-- What changes for the user (or the code), and why. Link the issue: "Fixes #12". -->

## How it was tested

<!-- Commands run, and for anything that touches fans or the daemon: the Mac model and macOS version. -->

- [ ] `make test` passes (both packages)
- [ ] Tested on real hardware: <!-- e.g. MacBook Pro M1 Pro, macOS 27.2 — or "not needed" -->
- [ ] Screenshots of visible changes, light and dark (`PulseSnapshots`)
- [ ] Idle CPU unchanged for app changes (`PulseBench`, every closed phase under 1 %)

## Checklist

- [ ] One change per pull request, into `dev`
- [ ] Docs updated if needed (README, `docs/HELP.md`, `docs/ARCHITECTURE.md`)
- [ ] Breaking change (config, command or script that stops working)? Then `!` in the title, e.g. `feat(cli)!: …`
