# Contributing to Pulse

Thanks for your interest in Pulse. This guide covers how changes flow from a branch to a release, what a pull request needs, and how to test a change that touches real hardware. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains where the code of each part lives and why.

## In short

1. Branch from **`dev`**: `feat/…`, `fix/…`, `docs/…`, `ci/…`, `chore/…`.
2. Open a pull request **into `dev`**, titled like a commit: `fix(app): keep the popover open after Install…`.
3. CI must pass (both packages and the title check), and the maintainer reviews it. It is squash-merged: one commit on `dev`.
4. When `dev` holds what the next version needs, the maintainer opens a pull request **from `dev` into `main`**. Merging it publishes the release.

Nobody pushes to `dev` or `main` directly.

## Branches

| Branch | Role | Receives | Merge method |
|---|---|---|---|
| `main` | Production: every commit is released or releasable | Pull requests from `dev` only | Merge commit |
| `dev` | Integration: the next release, tested together | Pull requests from feature branches | Squash |
| `feat/…`, `fix/…`, … | One change each, short-lived | Your commits | (deleted after the merge) |

Why these merge methods:

- **Squash into `dev`** turns each pull request into one commit whose message is the pull request's title. That commit is what the release reads to compute the version and write the notes (see [Versions](#versions)), so its title must follow the convention, and only the title matters.
- **Merge commit into `main`** keeps `main` and `dev` on the same history. A rebase or squash would create new commits on `main` that `dev` never had, and the two branches would diverge after the first release.

After a release, `dev` already contains everything on `main`: there is nothing to sync back.

## Pull request titles

The title of a pull request into `dev` becomes a commit on `dev`, so it follows [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<optional scope>): <what changes, in the imperative, lower case>
```

| Type | Use it for | Effect on the next release |
|---|---|---|
| `feat` | Something new for the user | Minor version: 1.2.0 → 1.3.0 |
| `fix` | A bug fix the user can notice | Patch version: 1.2.0 → 1.2.1 |
| `perf` | Faster or lighter, same behaviour | Patch version |
| `docs` | Documentation only | None on its own |
| `ci`, `build` | Workflows, packaging, scripts | None on its own |
| `test`, `refactor`, `style`, `chore` | No user-visible change | None on its own |

- Add `!` after the type (`feat(cli)!: …`) for a change that breaks existing configs, commands or scripts. That makes the next version a major one. Only the title reaches the commit (the squash message is left empty), so say it in the title, not only in the description.
- Common scopes: `app`, `cli`, `daemon`, `engine`, `smc`, `readme`, `help`, `release`. Leave the scope out when nothing fits.
- A pull request that only touches docs or CI does not publish anything by itself. It ships with the next release that has a `feat`, `fix` or `perf`.

The **Pull request title** check fails until the title matches. Edit the title, and the check runs again.

## Versions

Pulse follows [semantic versioning](https://semver.org/). Nobody picks a version by hand: when `dev` is merged into `main`, `scripts/next-version.sh` reads the commits since the last `vX.Y.Z` tag and takes the biggest bump among them. Several `fix` pull requests merged into `dev` between two releases make a single patch release.

The version is never committed. `Sources/ProductIdentity/PulseVersion.swift` holds `0.0.0-dev`, and the release build writes the real number before compiling. A development build never offers an update and never replaces a released daemon.

## What a pull request needs

- **One change.** A fix and an unrelated refactor are two pull requests.
- **Tests** for any logic you add or change. Run both packages: `make test`.
- **Screenshots** for any visible change to the app, in light and dark mode. `swift run --package-path App PulseSnapshots <dir>` renders every screen with sample data; add a case there if your screen is new. If the change shows in the README, run `make readme-images`: it regenerates the README's screenshots in both appearances.
- **No regression in idle CPU.** For changes to the app's views or polling, run `swift run -c release --package-path App PulseBench 20`. Every "closed" phase must stay under 1 % CPU.
- **Docs** that follow the change: [README.md](README.md) for what users see first, [docs/HELP.md](docs/HELP.md) for what a setting does (its numbers are checked by `HelpDocumentTests`).
- **The hardware you tested on**, for anything that writes to the SMC (see below).

The [pull request template](.github/pull_request_template.md) lists these as checkboxes.

## Testing on real hardware

Unit tests never touch the SMC: they run on fakes (`SampleService` in the app, a fake SMC backend in the daemon tests). CI machines have no fans to drive. A change to fan control therefore needs a run on a real Mac:

1. Build and install your version: `make app`, open `dist/Pulse.app`, then **Settings › Service › Reinstall…** (or `swift build -c release && sudo .build/release/pulse daemon install` for the CLI only).
2. `pulse doctor --test-fans` checks that every fan obeys and hands them back.
3. `pulse fan stress <profile>` (or **Stress Test…** in the app) heats the Mac under a curve and shows how the fans respond.
4. `scripts/hardware-campaign.sh` runs the full campaign (install, profiles, sleep, `kill -9`, safety guard, reboot…) and writes a report in `docs/campaign/`.

Every fan write goes through the daemon's safety guard, and quitting or killing the daemon hands the fans back to macOS. Still, watch the temperatures while you test, and run `pulse fan auto` if anything looks wrong.

Development builds are signed ad hoc, like releases: the daemon accepts writes from administrator accounts.

## Code style

- Swift 6 with strict concurrency, `swift-tools-version: 6.0`. Follow the style of the file you edit.
- Explain **why** in comments, not what. Keep comments up to date when you change the code next to them.
- Pulse is a fork of [smctl](https://github.com/leaperone/smctl) and merges its changes. Extend smctl's files instead of rewriting them, and put Pulse-specific code in separate files (`Pulse*.swift`). [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#working-with-upstream-smctl) explains how.
- Product names and paths (CLI name, daemon label, config path, URLs) live only in `Sources/ProductIdentity/ProductIdentity.swift`.
- User-facing text is in English, short and concrete. The design notes in `docs/ROADMAP.md` and `docs/PLAN.md` are in French; the smctl research notes in `docs/` are in Chinese.

## Reporting bugs

Open an [issue](https://github.com/fstormacq/pulse/issues/new/choose) with the output of `pulse doctor`. It lists the Mac, its fans and sensors, and the state of the service. For a fan that does not obey, add `pulse doctor --test-fans`.

## Releases (maintainer)

1. Make sure `dev` is green and holds what the release needs.
2. Open a pull request from `dev` into `main`. The **Release** check builds the next version as a preview and prints its number in the run's summary.
3. Merge it with **Create a merge commit**. The **Release** workflow then tests, builds `Pulse-X.Y.Z.zip` and `pulse-cli-X.Y.Z-arm64.tar.gz`, publishes the GitHub release, and updates the Homebrew tap [`fstormacq/homebrew-tap`](https://github.com/fstormacq/homebrew-tap).
4. For a first release, or to add an introduction to the notes, write `docs/release-notes/X.Y.Z.md` beforehand: the notes start with it.

`make release VERSION=X.Y.Z` does the same from a Mac, if the workflow is unavailable.

### Repository settings

These settings support the flow above; they are listed here so they can be checked or rebuilt.

- **General › Pull Requests**: allow merge commits and squash merging, not rebase merging; the commit title is the pull request's title and the message is left empty, for both. Automatically delete head branches (`dev` is protected from deletion by its ruleset, so merging `dev` into `main` keeps it).
- **Rules › Rulesets**:
  - `main`: require a pull request with 1 approval from a code owner, resolved conversations, the checks *Build & Test (macOS)* and *App Build & Test (macOS 26)*, allowed merge method *Merge*; block force pushes and deletion.
  - `dev`: the same, with allowed merge method *Squash*, the extra check *Pull request title*, and branches required to be up to date before merging.
  - Both: the maintainer may bypass, for pull requests only, to merge their own pull requests without a second reviewer.
- **Secrets › Actions**: `TAP_TOKEN`, a fine-grained token with *Contents: read and write* on `fstormacq/homebrew-tap` only, used by the release workflow to update the tap.
- **CODEOWNERS** (`.github/CODEOWNERS`) requests the maintainer's review on every pull request.
