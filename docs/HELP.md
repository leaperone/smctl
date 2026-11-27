# Pulse help

What each setting does to your fans, and what to do when something looks wrong.

- [How Pulse drives the fans](#how-pulse-drives-the-fans)
- [Profiles](#profiles)
- [Reading a curve](#reading-a-curve)
- [Response settings](#response-settings)
- [Sensor refresh](#sensor-refresh)
- [Automation](#automation)
- [Temperature limit](#temperature-limit)
- [Updates](#updates)
- [If something looks wrong](#if-something-looks-wrong)

## How Pulse drives the fans

A small background service, installed from **Settings › Service**, reads the temperature sensors and sets the fan speed. The app and the `pulse` command only talk to it, so the fans keep following your profile when Pulse is closed.

Speeds are in **percent of each fan's own range**: 0 % is its slowest spinning speed, 100 % its fastest. The same curve therefore suits a Mac mini and a MacBook Pro with two different fans.

On **Auto**, macOS drives the fans exactly as it would without Pulse.

## Profiles

| Profile | Behaviour | Follows | Ramp |
|---|---|---|---|
| **Auto** | macOS decides. Pulse only shows the readings. | – | – |
| **Silent** | Stays quiet as long as it can, then ramps up late and fast. | the hottest sensor | 80–105 °C |
| **Balanced** | Calm at rest, a clear rise in the middle of the range. | the hottest sensor | 70–100 °C |
| **Performance** | A straight ramp that cools early, for sustained work. Never below 10 %. | the CPU average | 55–90 °C |

The presets are read-only. Duplicate one in **Settings › Curves** to make your own version.

## Reading a curve

Left to right is temperature, bottom to top is fan speed. Below the first handle the fan runs at the curve's floor; above the last one, at its ceiling.

Drag the two handles to move where the ramp starts and ends, and the floor or ceiling. The **shape** sets how the speed climbs in between:

- **Linear**: steady.
- **S-curve**: calm, then a clear rise in the middle.
- **Exponential**: quiet for longer, then fast.
- **Logarithmic**: reacts early, then levels off.
- **Steps**: plateaus.
- **Points**: free points you place yourself.

**Steepness** is how abrupt the ramp is between its two handles. Low: the speed changes gradually across the whole range. High: little change near the ends and a quick rise in the middle (S-curve), or early (logarithmic) or late (exponential).

The live marker shows the current temperature and the speed the curve asks for. The faint lines are the presets, for reference.

## Response settings

**Sensors.** Which temperatures drive the curve. CPU and GPU are the chip's hot spots; they react fastest to load. Unchecking everything uses every sensor.

**Hottest or average.** *Hottest*: the curve follows the warmest checked sensor, so any hot spot speeds the fan up (safest, Apple's own approach). *Average*: the mean of the checked sensors, calmer but slower to react to one busy core.

**Smoothing.** Averages the temperature over this many seconds before reading the curve, so a one-second spike (opening an app) doesn't rev the fan. Longer is quieter but reacts later to sustained load.

**Hysteresis.** Once the fan has sped up, the temperature must drop this much before it slows down again. Prevents the fan from going up and down when the temperature hovers around a step.

**Speed up and slow down.** How fast the fan may change speed, in % of its range per second. Lower values make speed changes gradual and less noticeable; *Immediate* follows the curve at once. Slowing down more gently than speeding up keeps the fan from pulsing.

**At 0 %.** What happens when the curve asks for 0 %:

- **macOS decides** (default): Pulse hands the fan back to macOS after 15 s, which usually keeps it at its quiet minimum, or stops it on a cool MacBook.
- **Minimum speed**: Pulse holds the lowest speed itself.
- **Stopped**: the fan stops completely. Experimental, and only allowed when `allow_below_minimum` is set in the configuration.

## Stress test

To tune a curve, click **Stress Test…** next to it. Pulse heats every CPU core (and the GPU, unless you pick *CPU*) for 1, 2 or 5 minutes, then records the cool-down. The charts show the CPU and GPU temperatures, the temperature the curve acts on after smoothing, and the fan speed. At the end, a summary gives:

- **CPU, steady** and **Fan, steady**: averages over the last 30 s of heating. A large ± after the fan speed means it hunts: add smoothing or hysteresis, or slow its fall.
- **Speeds up**: when the fan got 300 RPM above where it started, and the CPU temperature then. Late means the ramp starts too high, or smoothing is long.
- **Back to rest**: how long after the heat stopped the fan returned to its starting speed.

Change the curve, save it, and run the test again: the previous run is drawn faded and listed next to the new one. The test runs the saved curve, and your current profile comes back at the end, even if you stop early.

While the test runs, it owns the fan profile: the popover's profiles are locked (it shows *Stress test running* with a *Stop* button) and automation rules wait. Switching curves in the middle would not compare them anyway: the fan would start from the speed the previous curve left. If the profile changes all the same (from Terminal, for example), the test stops and the run is not kept for comparison. To compare curves, use `pulse fan stress` with several of them, below.

From Terminal (over SSH, for example): `pulse fan stress night`, or `pulse fan stress balanced night` to compare two curves under the same load. Each one waits for the Mac to cool back to the starting temperature first. Options: `--load` and `--cool` (seconds), `--cpu-only`, `--csv <file>` for every sample, `--json`.

## Sensor refresh

**Settings › General › Sensors** sets how often the service reads the sensors, from 1 to 5 seconds (2 s by default). Shorter reacts faster to heat; longer uses less energy. Readings and charts in Pulse update at the same pace.

Curves keep their character at any pace: how fast the fan may change speed is measured in real time, so a longer interval only delays the reaction a little.

On a MacBook you can choose a **slower pace on battery**. The service switches by itself when you unplug or plug in, even with Pulse closed.

Near the temperature limit the service reads every second, whatever the setting.

From Terminal: `pulse fan interval 3`, `pulse fan interval 5 --on-battery`, or `pulse fan interval same --on-battery` to drop the battery pace.

## Automation

Rules in **Settings › Automation** switch the profile on their own: while a game or app is open, in Low Power Mode, on battery or on the power adapter. A condition must hold for a few seconds before the switch, and the first rule that applies wins.

When no rule applies, Pulse goes back to the profile you chose. Picking a profile yourself always wins until the rule's condition goes away. Rules run while Pulse is open.

## Temperature limit

A safety guard watches every sensor while Pulse drives the fans. If one stays above **100 °C** (**110 °C** for the chip's hot spots), or if no sensor can be read, it hands the fans back to macOS at once. It cannot be turned off.

The Mac then stays on Auto and Pulse notifies you. It means the cooling could not keep up: check the Mac's vents and the curve, then pick a profile again to resume. Automatic rules wait for that choice too.

## Updates

When a new version is out, the menu bar popover says so, with the command to run in Terminal (`brew upgrade --cask fstormacq/tap/pulse`) or a link to download it. *Later* hides the notice until the next version; **Settings › About** still shows it.

After an update, Pulse replaces the fan control service with its own version the next time it starts. macOS asks for your password once. If you cancel, the popover shows *The fan control service is out of date* with an *Update…* button. Your profile, curves and settings are kept. With the command line only (`brew upgrade fstormacq/tap/pulse-cli`), the next `pulse` command in Terminal does the same through `sudo`.

## If something looks wrong

**Fans not following the curve.** Check that the service is installed and up to date in **Settings › Service** (the popover warns when it is out of date), and that no other fan app (TG Pro, Macs Fan Control, …) is running. Pulse warns when it finds one.

**Temperatures but no fan readings.** This Mac has no fan (MacBook Air). Pulse shows temperatures only.

**For a bug report**, run this in Terminal and paste the output in the issue:

```console
$ pulse doctor
```

It lists the Mac, its fans and sensors, and the service's state. `pulse doctor --test-fans` also checks that each fan obeys, then restores your profile.
