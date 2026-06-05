# smctl

[![CI](https://github.com/leaperone/smctl/actions/workflows/ci.yml/badge.svg)](https://github.com/leaperone/smctl/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20(Apple%20Silicon)-lightgrey.svg)](https://github.com/leaperone/smctl)

> The missing control knob for your Mac's SMC.

**smctl** is an open-source, CLI-first tool for controlling the hardware your Mac normally manages for you — fan speed, battery charging, and power telemetry — straight from the terminal.

English | [中文](docs/README.zh-CN.md)

![smctl demo](docs/assets/demo.gif)

```console
$ smctl battery maintain 70-80     # keep the battery between 70% and 80%
$ smctl fan profile quiet          # custom fan curve, stays silent until hot
$ smctl sensors --watch            # live temperatures, fan RPM, package power
```

## Why

- **Your battery ages fastest at 100%.** macOS only offers an opaque, ML-driven "Optimized Charging" and a single fixed 80% option. smctl gives you an explicit, deterministic charge limit with a sailing range — set it once, sync it in your dotfiles.
- **Apple Silicon Macs expose no fan control at all.** No official API, no third-party CLI — smctl implements manual fan targets and declarative fan curves on Apple Silicon, with a built-in thermal safety guard.
- **Headless Macs deserve first-class tooling.** Running a Mac mini as a home server? Every feature works over SSH, every command has `--json` output for scripting.

## Features

| Command | What it does |
|---|---|
| `smctl sensors [--watch] [--json]` | Temperatures by sensor group, fan RPM/mode, battery, package power |
| `smctl battery status` | Charge level, charging state, configured limit |
| `smctl battery maintain 80` / `70-80` / `stop` | Charge limit with dead-band (no charge/discharge flapping) |
| `smctl battery charge 90` / `discharge 40` | One-shot top-up or supervised discharge |
| `smctl fan status` | Per-fan actual/target/min/max RPM and control mode |
| `smctl fan set 2500 [--fan N]` | Manual fan target |
| `smctl fan profile quiet\|full\|auto\|<custom>` | Declarative fan curves (TOML), hysteresis + slew-rate limited |
| `smctl daemon install\|uninstall\|status\|ping` | Manage the privileged helper |

Policies live in `/etc/smctl/config.toml` — declarative, diffable, dotfiles-friendly.

## Install

### Homebrew (recommended)

```console
$ brew install leaperone/smctl/smctl
$ sudo smctl daemon install
```

Or tap once and use short names from then on:

```console
$ brew tap leaperone/smctl
$ brew install smctl        # later: brew upgrade smctl
```

### From source

```console
$ git clone https://github.com/leaperone/smctl && cd smctl
$ swift build -c release
$ sudo .build/release/smctl daemon install
```

### Signed binaries

Each [release](https://github.com/leaperone/smctl/releases) ships a zip with `smctl` + `smctld`, Developer ID signed and notarized by Apple.

Charge limiting and fan control are applied by `smctld`, a root LaunchDaemon. The CLI talks to it over XPC; reading sensors needs no daemon and no root.

## Safety by design

Controlling fans and charging from userspace demands paranoia. smctl treats these as first-class invariants:

- **Never leave a brick.** Uninstalling, stopping, or killing the daemon restores system control of fans and charging — enforced by termination hooks, startup reconciliation, and launchd restart.
- **Thermal safety guard.** While fans are under manual control, smctl monitors all temperature sensors every second. Sustained readings above the ceiling (default 100 °C, hard-capped at 105 °C, cannot be disabled) force fans back to system control and latch out manual control until things cool down. Losing temperature visibility counts as unsafe.
- **Verified writes.** Every SMC write is read back and verified (with a settle window for firmware that applies writes asynchronously) — failures surface as errors, never as silent no-ops.
- **Graceful degradation.** If a macOS update changes SMC behavior, affected features degrade to read-only with an explicit message instead of pretending to work.

## Supported hardware

- **Apple Silicon Macs, macOS 14+.**
- Fan control fully verified on **M4 Mac mini** (direct-write path). The diagnostic-unlock fallback path for machines that need it (some MacBook Pro generations) is implemented per published research but needs more real-hardware coverage — [reports welcome](https://github.com/leaperone/smctl/issues).
- Battery charge control targets the same SMC keys used by established tools (pre-Tahoe and macOS 26 key sets, runtime-detected); broader machine coverage is in progress.
- Intel Macs: not yet (sensors are read-only there for now).

Capability detection is done at runtime — on unsupported hardware, commands tell you exactly what's unavailable rather than failing silently.

## How it compares

| | smctl | macOS built-in | AlDente | Macs Fan Control | stats |
|---|---|---|---|---|---|
| CLI / scriptable | ✅ | — | — | — | — |
| Battery charge limit | ✅ custom range | 80% fixed | ✅ | — | — |
| Fan control (Apple Silicon) | ✅ curves | — | — | ✅ GUI only | — |
| Declarative config | ✅ TOML | — | — | — | — |
| Open source | ✅ MIT | — | — | — | ✅ |

## Roadmap

- Homebrew tap, then homebrew-core
- `smctl battery calibrate`, thermal-throttling visibility (`smctl power`)
- Menu bar app (the daemon already speaks XPC; a GUI is just another client)

## Documentation

- [中文项目文档](docs/README.zh-CN.md) — vision, research notes, and roadmap (Chinese)
- [Architecture & design](docs/design.md) (Chinese)
- [Field notes: M4 Mac mini](docs/field-notes-m4-mini.md) — real-hardware findings, including SMC asynchronous-write behavior (Chinese)

## License

[MIT](LICENSE)

## Disclaimer

smctl writes to your Mac's System Management Controller. The safety mechanisms above are engineered conservatively, but you use it at your own risk — especially manual fan control under sustained load.
