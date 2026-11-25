<p align="center">
  <img src="assets/img/banner.png" alt="Pulse" width="600">
</p>

# Pulse

**Temperatures and fan speed in your Mac's menu bar, with full control over the fans.**

Pulse is a lightweight, native Swift app for Apple Silicon Macs:

- **Menu bar**: live temperature and fan RPM, in a compact native popover.
- **Fan profiles**: several profiles you can switch with one click (Silent, Balanced, Performance, or your own).
- **Custom curves**: percent-based curves built from predefined shapes (linear, sigmoid, exponential, steps) that you stretch or compress to get more or less reactivity.
- **`pulse` CLI**: an overview of the Mac's state and fan configuration over SSH.
- **Safe by design**: a privileged daemon does all the hardware writes, falls back to system control whenever something goes wrong, and applies a thermal safety guard that cannot be disabled.

> 🚧 **Work in progress.** The app and the `pulse` CLI are under development.

## Built on smctl

Pulse is a fork of [**smctl**](https://github.com/leaperone/smctl) by harryisfish and contributors (MIT). smctl provides the SMC layer, the privileged daemon, the fan curve engine and its safety mechanisms, plus battery, power and display control. Pulse keeps all of it and regularly merges upstream changes. Pulse adds the menu bar app, the profile and curve model, and the `pulse` CLI.

The original smctl documentation is in [docs/smctl-README.md](docs/smctl-README.md).

## License

[MIT](LICENSE). © 2026 Florian Stormacq, and © 2026 harryisfish and the smctl contributors.
