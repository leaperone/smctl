# smctl

[![CI](https://github.com/leaperone/smctl/actions/workflows/ci.yml/badge.svg)](https://github.com/leaperone/smctl/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20(Apple%20Silicon)-lightgrey.svg)](https://github.com/leaperone/smctl)

> The missing control knob for your Mac's SMC.

**smctl** is an open-source, CLI-first tool for controlling the hardware your Mac normally manages for you — fan speed, battery charging, and power telemetry — straight from the terminal.

**smctl** 是一个开源、命令行优先的 Mac 硬件控制工具：风扇曲线、电池充电限制、温度/功耗遥测——这些 macOS 不开放的控制能力，一条命令搞定。

English | [中文文档](docs/README.zh-CN.md)

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
| `smctl power status [--watch] [--json]` | Thermal pressure, CPU throttling (% speed limit), package + input power |
| `smctl alert status\|test <name>` | Temperature/event alerts → webhook, command, or log (configured in TOML) |
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

The Homebrew install sets up shell completions (bash/zsh/fish) and a `man smctl` page automatically.

## Safety by design

Controlling fans and charging from userspace demands paranoia. smctl treats these as first-class invariants:

- **Never leave a brick.** Uninstalling, stopping, or killing the daemon restores system control of fans and charging — enforced by termination hooks, startup reconciliation, and launchd restart.
- **Thermal safety guard.** While fans are under manual control, smctl monitors all temperature sensors every second. Sustained readings above the ceiling (default 100 °C, hard-capped at 105 °C, cannot be disabled) force fans back to system control and latch out manual control until things cool down. Losing temperature visibility counts as unsafe.
- **Verified writes.** Every SMC write is read back and verified (with a settle window for firmware that applies writes asynchronously) — failures surface as errors, never as silent no-ops.
- **Graceful degradation.** If a macOS update changes SMC behavior, affected features degrade to read-only with an explicit message instead of pretending to work.

## Privacy

The daemon makes outbound network requests in exactly two cases, both under your control:

1. **Update check** — a once-a-day check of the GitHub releases API to learn the latest version, surfaced by the CLI as an upgrade hint. On by default; turn it off with `[update] check = false`.
2. **Alert webhooks** — only the webhook URLs *you* configure in `[[alert]]` rules. No alerts configured (the default) means no such requests.

There is no telemetry and no analytics. The CLI itself never makes network requests — all outbound traffic originates in the daemon, from the two opt-in/opt-out cases above. To go fully offline, set:

```toml
[update]
check = false
```

in `/etc/smctl/config.toml` (then `sudo smctl daemon restart`) and configure no webhook alerts.

## Alerts

The daemon already watches every temperature sensor once a second for the thermal safety guard. Alert rules hang off that same loop: when a condition holds, the daemon runs an action — a shell command, an HTTP webhook, or a log line. Useful for a headless Mac mini wired into Prometheus/Gotify/etc.

Rules are declarative TOML in `/etc/smctl/config.toml`:

```toml
[[alert]]
name = "cpu-hot"
on = "temp"            # temp | guard | write-error
sensor = "Tp09"        # a sensor key, or "any" for the hottest
above = 85             # °C
for = 30               # must hold this many seconds before firing (debounce)
cooldown = 300         # silence re-firing for this many seconds
resolve = true         # also fire once when the condition clears
action = "webhook"     # webhook | exec | log
url = "http://gotify.lan/message?token=..."

[[alert]]
name = "guard-tripped"
on = "guard"           # the thermal safety guard forced fans back to auto
action = "exec"
command = ["/usr/local/bin/notify.sh", "{name}", "{reason}"]
```

`exec` commands receive the event as both substituted argv placeholders (`{name}` `{kind}` `{trigger}` `{reason}` `{value}`) and `SMCTL_ALERT_*` environment variables. Inspect and verify rules with:

```console
$ smctl alert status          # per-rule state + recent events
$ smctl alert test cpu-hot    # fire the action now, to check your webhook/script
```

> **Security:** `exec` actions run as **root** (the daemon is root). The trust boundary is whoever can edit the root-owned `/etc/smctl/config.toml` — the same boundary as every other policy. Commands run via argv arrays only (no shell), so there is no command-injection surface, but treat write access to the config as equivalent to root.

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
- Thermal-throttling visibility (`smctl power`)
- `smctl battery calibrate` — planned, pending validation on a MacBook (calibration must run inside the daemon to avoid fighting the maintain loop, and needs real battery hardware to verify)
- Menu bar app (the daemon already speaks XPC; a GUI is just another client)

## Documentation

- [中文项目文档](docs/README.zh-CN.md) — vision, research notes, and roadmap (Chinese)
- [Architecture & design](docs/design.md) (Chinese)
- [Field notes: M4 Mac mini](docs/field-notes-m4-mini.md) — real-hardware findings, including SMC asynchronous-write behavior (Chinese)

## License

[MIT](LICENSE)

## Disclaimer

smctl writes to your Mac's System Management Controller. The safety mechanisms above are engineered conservatively, but you use it at your own risk — especially manual fan control under sustained load.
