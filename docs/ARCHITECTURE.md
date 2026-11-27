# Pulse architecture

Where the code of each part of Pulse lives, why it is split that way, and how to make the most common changes. For the contribution workflow (branches, pull requests, releases), see [CONTRIBUTING.md](../CONTRIBUTING.md).

## The big picture

```
 Pulse.app (menu bar)          pulse (CLI)
 App/Sources/PulseUI           Sources/smctl
        │                            │
        └──────── XPC ───────────────┘          unprivileged clients
                   │  SMCtlClient (DaemonClient) ↔ SMCtlProtocol (DTOs)
                   ▼
            pulsed (root LaunchDaemon)
            Sources/smctld → SMCtlDaemonCore
             ├─ PolicyEngine: curves, smoothing, safety guard, battery policy
             ├─ /etc/pulse/config.toml
             └─ SMCCore ──IOKit──▶ AppleSMC (sensors, fans)
```

Three programs, one source of truth:

- **`pulsed`** is the only process that writes to the hardware. It runs as root, from a copy in `/Library/PrivilegedHelperTools/` that launchd keeps alive. It reads the sensors on a timer, runs the active fan curve, writes the fans, and enforces the safety guard. It owns `/etc/pulse/config.toml`.
- **`pulse`** (the CLI) and **Pulse.app** are clients. They ask the daemon over XPC (mach service `com.stormacq.pulse.daemon`) and never write to the SMC themselves. Without a daemon, the app falls back to reading the sensors directly, read-only, which needs no privileges.
- **The config file** is the single source of truth for curves and settings. The app and the CLI change it through the daemon, which validates every change before saving it. A user can also edit it by hand or over SSH.

Why a root daemon: writing to the SMC needs root, and a fan left in manual mode by a crashed process would stay there. A small root service that launchd restarts, that hands the fans back to macOS on every exit path, and that validates every request is the smallest privileged surface.

## Two Swift packages

| Package | Path | Platforms | Contents |
|---|---|---|---|
| **Core** | `Package.swift`, `Sources/`, `Tests/` | macOS 14+ | The SMC layer, the policy engine, the daemon, the XPC protocol and client, the CLI. Builds with the Command Line Tools. |
| **App** | `App/Package.swift`, `App/Sources/`, `App/Tests/` | macOS 26+ | The menu bar app and its tools. Depends on the core package. Needs Xcode 26 (SwiftUI macros). |

The split keeps the CLI and the daemon on macOS 14 and buildable without Xcode, while the app uses the latest SwiftUI. Open `App/Package.swift` in Xcode to work on the app; there is no `.xcodeproj`.

## Core package: `Sources/`

Modules are listed from the bottom of the dependency graph to the top.

### `ProductIdentity`: names and the version

| File | What |
|---|---|
| `ProductIdentity.swift` | Every product-specific name: CLI and daemon names, mach service, LaunchDaemon and helper paths, config path, log subsystem, GitHub and Homebrew names. |
| `PulseVersion.swift` | The version, `0.0.0-dev` in the repository. `scripts/set-version.sh` writes the real one for a release build. |

**Why**: smctl's code refers to these constants instead of literals, so Pulse could rename everything (smctl → pulse, `dev.smctl.*` → `com.stormacq.pulse.*`) by editing one file, and upstream merges do not conflict on names.

### `SMCCore`: talking to the hardware

| File | What |
|---|---|
| `SMCConnection.swift` | The IOKit connection to `AppleSMC`: read and write a key. Implements `SMCWriteBackend`. |
| `SMCBackend.swift` | `SMCBackend` / `SMCWriteBackend` protocols (faked in tests), write retries and verified writes. |
| `SMCParamStruct.swift`, `SMCDataDecoder.swift`, `FourCharCode.swift` | The kernel structure layout and the SMC data types (`flt`, `ui8`, `fpe2`…). |
| `KeyCatalog.swift` | Which keys exist on this Mac (fans, charging control groups), probed at runtime against a data table. |
| `FanControl.swift` | `FanController`: manual and automatic modes, the unlock path (direct, or the `Ftst` gate on M3/M4 MacBooks), with timing tuned for asynchronous SMC writes. |
| `SensorSnapshot.swift` | `SensorReader`: one snapshot of every temperature, fan and power key. |
| `PowerStatus.swift` | Thermal pressure and power source. |

**Why**: everything that depends on Apple's undocumented SMC interface is here, behind protocols, so the rest of the code can be tested without hardware and a macOS change has one place to land.

### `PolicyEngine`: decisions, without side effects

| File | What |
|---|---|
| `FanCurveSpec.swift` | A curve as data: points or shape, sensors, hysteresis, rise and fall rates, smoothing, idle behaviour, validation. The built-in presets (`FanCurvePresets`: silent, balanced, performance) and reserved names. |
| `FanCurveShape.swift` | The shapes (linear, sigmoid, exponential, logarithmic, steps) as normalized functions, compiled to ~32 points, and `FanSpeedRange` (% ↔ RPM for one fan). |
| `PolicyEngine.swift` | `FanCurveEngine` (aggregation, smoothing, hysteresis, rate limiting), `FanSafetyGuard`, and smctl's battery and sleep state machines. |
| `AlertEngine.swift` | smctl's alert rules. |

**Why**: pure functions of their inputs and a clock (`PolicyClock`). The daemon runs them on real readings; the app runs the same code to draw a live preview of a curve being edited (`CurvePreview`). Every behaviour of a curve is unit-tested here, without a daemon.

### `SMCtlProtocol`: the XPC contract

| File | What |
|---|---|
| `SMCtlProtocol.swift` | smctl's XPC protocol and DTOs (ping, fans, battery, alerts…), version comparison (`SMCtlProtocolInfo`). |
| `PulseProtocol.swift` | `PulseDaemonXPCProtocol`, which extends smctl's: `getTelemetry`, curve CRUD, sampling interval. `TelemetryDTO` is the one-call snapshot the app polls. |

Every method takes and returns JSON-encoded `Data` (`SMCtlProtocolCoding`), so adding an optional field never breaks an older client or daemon. Keep it that way: new fields are optional, or decoded with `decodeIfPresent`.

### `SMCtlClient`: shared client code

| File | What |
|---|---|
| `DaemonClient.swift` | The XPC connection, a blocking `call` with a timeout, and the version checks (daemon older than the client, newer release available). |
| `PulseDaemonClient.swift` | Pulse's calls on that connection. |
| `PulseSystemInfo.swift` | Sensor groups (CPU `Tp*`, GPU `Tg*`, board `Ts*`) and summaries; detection of other fan apps. |
| `PulseStress.swift` | The stress test engine (CPU and Metal load, sampling, summary), used by `pulse fan stress` and the app. |
| `PulseUpdates.swift` | `InstallChannel` (cask, formula, download, source) and `DaemonUpdateDecision` (when to replace the daemon). |

**Why**: everything the CLI and the app both need, so they behave the same.

### `SMCtlDaemonCore` and `smctld`: the daemon

| File | What |
|---|---|
| `Daemon.swift` (smctl) | `SmctlDaemon`: config loading and atomic saving, timers, sleep and wake, battery policy, the XPC listener and `XPCService`, write authorization. |
| `PulseFanCurves.swift` | Pulse's fan curve runtime: compiling shapes, running the active curve at each read, the write dead band, handing fans back to macOS at 0 %, telemetry, and the Pulse XPC methods. |
| `PulseSampling.swift` | The configurable sensor interval (1–5 s, slower on battery, every second near the safety ceiling). |
| `CodeSignPolicy.swift` | Client authorization: same Team ID for Developer ID builds; for ad hoc builds (Pulse's case), writes are allowed to root and administrator accounts. |
| `Alerting.swift`, `PowerSourceTimeEstimate.swift`, `SentryReporting.swift` | smctl's alerts, battery estimates and optional crash reporting (off without a DSN). |
| `smctld/main.swift` | A logic-free entry point that starts `SmctlDaemon`. |

At every sensor read, the daemon: reads a snapshot → checks the safety guard → runs the active curve for each fan (`FanCurveEngine`) → writes a fan only when the target moved enough (the dead band) or macOS took the fan back. Exiting, crashing or being uninstalled hands the fans back to macOS (exit hooks, reconciliation at start).

### `smctl`: the CLI (`pulse`)

| File | What |
|---|---|
| `SMCtl.swift` (smctl) | The command tree (ArgumentParser), smctl's commands, `daemon install|uninstall|restart|status|logs`, and `main()`, which installs the daemon auto-update hook. |
| `PulseCommands.swift` | `pulse status`, `pulse fan curve …`, `pulse fan interval`, `pulse fan stress`. |
| `DoctorCommand.swift` | `pulse doctor`: the diagnostic report for bug reports. |
| `DaemonAutoUpdate.swift` | Replaces an older daemon through `sudo` on the first command in a terminal. |
| `Display.swift` | smctl's display control (DDC), with the C helpers in `Sources/DisplayDDC`. |

`pulse daemon install` copies the `pulsed` found next to the CLI (following symlinks, so Homebrew's `bin` and the app's `Contents/Helpers` both work) into `/Library/PrivilegedHelperTools/` and registers the LaunchDaemon.

## App package: `App/Sources/`

| Target | What |
|---|---|
| `PulseApp` | The executable: `PulseApp.swift` wires the store, the status item, settings, automation and notifications. |
| `PulseUI` | Everything else, as a library so tests and tools can use it. |
| `PulseSnapshots` | Renders every screen with sample data to PNG files, light and dark. |
| `PulseBench` | Measures the app's CPU and memory with the real status item and windows. |
| `PulseLiveCheck` | Runs the curve editor's save path against the installed daemon, then cleans up. |

### `PulseUI/Model`: state and logic

| File | What |
|---|---|
| `PulseStore.swift` | The app's state: polls the daemon at its sensor interval, keeps a short history, exposes profiles, runs user actions. Observable, main actor; blocking calls run detached. |
| `PulseService.swift` | The `PulseService` protocol: `DaemonPulseService` (XPC) and `DirectSensorService` (read-only fallback). |
| `SampleService.swift` | An in-memory `PulseService` with Mac mini readings, for tests, previews and snapshots. |
| `UpdateCenter.swift` | New releases and the daemon's version after an upgrade (automatic replacement behind the password prompt). |
| `ServiceInstaller.swift` | Installs or removes the daemon and the CLI link with the bundled helpers, behind the macOS administrator prompt; launch at login. |
| `CurveDraft.swift`, `CurveEditorModel.swift`, `CurvePreview.swift`, `CurveNaming.swift`, `CurveSummary.swift`, `FanRangeNote.swift` | The curve editor: an editable copy of a curve with undo, chart interactions, the live preview computed with `PolicyEngine`, names and plain-language summaries. |
| `Automation.swift`, `AutomationController.swift` | Rules that switch the profile (apps open, Low Power Mode, battery, adapter) and the system signals they watch. |
| `SafetyAlerts.swift` | Notifications when the safety guard engages and releases. |
| `StressTest.swift` | The stress test sheet's model and the previous run per curve. |
| `AppSettings.swift`, `SettingsNavigation.swift`, `ActivationGuard.swift` | Menu bar preferences, settings navigation, keeping the window in front after the password prompt. |

### `PulseUI/Views` and the menu bar

| File | What |
|---|---|
| `StatusItemController.swift` | The menu bar item and popover, in AppKit (`NSStatusItem`, `NSPopover`). SwiftUI's `MenuBarExtra` redrew the item at every update (~3.6 % CPU at idle). |
| `MenuBarRenderer.swift` | Draws the menu bar image: icon, heartbeat, stacked or inline readings. |
| `PopoverView.swift`, `UpdateNotices.swift` | The popover: notices, temperatures, fans, history, profiles. |
| `SettingsView.swift` | The settings window and its panes: General, Curves, Automation, Service, About. |
| `CurvesSettings.swift`, `CurveEditor.swift`, `CurvesChart.swift`, `CurveSettingsForm.swift`, `InfoButton.swift` | The Curves pane and editor. |
| `AutomationSettings.swift`, `SamplingSettings.swift`, `StressTestSheet.swift` | Other panes and sheets. |

**Performance rule**: views read only what they show, the store assigns a property only when its value changed, and closed windows release their views. `PulseBench` checks all three.

## Configuration

`/etc/pulse/config.toml` is read by the daemon at start and on `reloadConfig`, and written by it after each change, atomically (write to a temporary file, then rename). If the file fails to parse, the daemon keeps running on the last valid config and refuses to overwrite the file. The TOML mapping is in `Daemon.swift` (`DaemonConfig`, `FanConfig`, `FanCurveConfig`) and `PulseFanCurves.swift` (`FanShapeConfig`). A round-trip test covers the serializer.

## Tests

| Target | Covers |
|---|---|
| `Tests/PolicyEngineTests` | Curves, shapes, the safety guard, battery and sleep state machines. |
| `Tests/SMCCoreTests` | Decoding, struct layout, write retries, fan unlock and the `Ftst` gate, on fake backends. |
| `Tests/SMCtlDaemonCoreTests` | The daemon on a fake SMC: curves, persistence, safety guard, config compatibility. |
| `Tests/SMCtlProtocolTests` | DTO compatibility between versions, version comparison. |
| `Tests/SMCtlClientTests` | Client coding, stress test summary, sensor groups, update decisions. |
| `Tests/smctlTests` | CLI output and options, `doctor`, install paths, the daemon auto-update rules. |
| `App/Tests/PulseUITests` | Store, editor, automation, updates, notices, help document, on `SampleService`. |

`make test` runs both packages. CI runs them on every pull request, on macOS runners without SMC access, so tests must never need real hardware.

## Build, release and distribution

| Path | What |
|---|---|
| `Makefile` | Entry points: `build`, `test`, `app`, `package`, `next-version`, `notes`, `tap`, `release`. `make help` lists them. |
| `scripts/build-app.sh` | Builds `dist/Pulse.app`: the app with `pulse` and `pulsed` in `Contents/Helpers`, signed ad hoc. |
| `scripts/set-version.sh`, `scripts/next-version.sh`, `scripts/release-notes.sh` | The version for a build, the next version from the commits, the release notes. |
| `scripts/package.sh` | The release assets and their checksums in `dist/release/`. |
| `scripts/update-tap.sh`, `packaging/homebrew/` | The cask and formula templates, rendered into the tap for a version. |
| `.github/workflows/ci.yml` | Build and tests of both packages. |
| `.github/workflows/release.yml` | The release on every push to `main` (preview only on pull requests). |
| `.github/workflows/pr-title.yml` | Checks that a pull request's title follows the commit convention. |
| `scripts/hardware-campaign.sh`, `scripts/campaign/`, `scripts/test-safety-notification.sh`, `scripts/gamemode-probe.sh` | Hardware tests and probes, run by hand on a real Mac. |

Pulse is signed ad hoc, without an Apple Developer account. The Homebrew cask removes the quarantine attribute after installing, so Gatekeeper does not block the app. The daemon runs from a root-owned copy that no upgrade replaces, which is why the app and the CLI replace it themselves after an upgrade (`UpdateCenter`, `DaemonAutoUpdate`).

## How to…

### Add a CLI command

Add a `ParsableCommand` in `Sources/smctl/PulseCommands.swift` (or a new `Pulse…Command.swift` file) and register it in its parent's `subcommands`. Support `--json` with `CLIJSON`. If it needs the daemon, call it through `DaemonClient` and wrap errors with `withDaemon`/`mapDaemonClient`. Test argument parsing and output in `Tests/smctlTests`.

### Add a daemon method

1. Add the method to `PulseDaemonXPCProtocol` and its request/response DTOs to `PulseProtocol.swift`, all fields optional or with defaults.
2. Implement it in the `XPCService` extension in `PulseFanCurves.swift`, with `authorizeWrite()` first if it changes anything, then the logic on `SmctlDaemon` (on its queue).
3. Expose it in `PulseDaemonClient.swift`, then in the CLI and, for the app, in `PulseService` (and `SampleService`).
4. Test the daemon side in `Tests/SMCtlDaemonCoreTests` and the coding in `Tests/SMCtlProtocolTests`.

An older daemon does not have the new method: the client gets an error, which the app and the CLI must handle (the daemon updates itself shortly after an upgrade, but not instantly).

### Add a field to the config

Add it to the matching `…Config` struct with a default, decoded with `decodeIfPresent`, so older files keep loading. Add it to the serializer (`writeConfig` in `Daemon.swift`) and extend the round-trip tests in `Tests/SMCtlDaemonCoreTests`. Document it in the README's configuration section.

### Add a curve setting or a preset

Curve settings live in `FanCurveSpec` (validated there), are mapped to TOML in `FanCurveConfig`, used by `FanCurveEngine`, and edited in the app through `CurveDraft` and `CurveSettingsForm`. Presets are in `FanCurvePresets`; their numbers also appear in the README and `docs/HELP.md`, which `HelpDocumentTests` checks.

### Change something in the app's UI

Change the view and its model, add or update a case in `PulseSnapshots`, render it (`swift run --package-path App PulseSnapshots /tmp/shots`) and look at both appearances. Run `PulseBench` if the change touches polling or a view that stays alive while closed.

### Rename the product or change an identifier

Edit `Sources/ProductIdentity/ProductIdentity.swift` only. Changing the mach service or paths needs a reinstall of the daemon, and old paths go into `legacyLaunchDaemonPlistPaths` so `daemon uninstall` cleans them up.

## Working with upstream smctl

Pulse is a fork of [leaperone/smctl](https://github.com/leaperone/smctl) and merges its changes:

```console
$ git remote add upstream https://github.com/leaperone/smctl.git   # once
$ git fetch upstream && git switch -c chore/merge-upstream dev
$ git merge upstream/main
```

To keep those merges easy:

- **Extend, don't rewrite.** smctl's files (`Daemon.swift`, `SMCtl.swift`, `PolicyEngine.swift`…) change as little as possible. Pulse's additions live in separate files (`PulseFanCurves.swift`, `PulseCommands.swift`, `PulseProtocol.swift`…), as extensions where possible.
- **Names go through `ProductIdentity`**, never as literals.
- **Generic improvements are kept as isolated, tested commits** (percent curves, shapes, the write dead band…), so they can be proposed to smctl as pull requests.

## Further reading

- [docs/HELP.md](HELP.md): what each setting does, for users.
- [docs/ROADMAP.md](ROADMAP.md) and [docs/PLAN.md](PLAN.md): technical choices, the step-by-step plan and its journal (in French).
- [docs/smctl-README.md](smctl-README.md), [docs/design.md](design.md) and the `research-*.md` notes: smctl's own design and research (in Chinese).
- [docs/field-notes-m4-mini.md](field-notes-m4-mini.md): measurements on a Mac mini M4 (in Chinese).
