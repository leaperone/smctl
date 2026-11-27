# fstormacq/tap

Homebrew tap for [Pulse](https://github.com/fstormacq/pulse): temperatures and fan control for Apple silicon Macs.

```sh
brew tap fstormacq/tap && brew trust fstormacq/tap
brew install --cask fstormacq/tap/pulse     # the menu bar app, with the pulse CLI (macOS 26 or later)
brew install fstormacq/tap/pulse-cli        # or: the pulse CLI and its daemon only (macOS 14 or later)
```

Install one or the other: both provide the `pulse` command.

This repository is updated by the release workflow of fstormacq/pulse (`scripts/update-tap.sh`): do not edit it by hand.
