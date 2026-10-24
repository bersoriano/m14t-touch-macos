# Lenovo ThinkVision M14t display touch driver for macOS

> A tiny, dependency-free macOS driver that brings touchscreen input to the
> **Lenovo ThinkVision M14t** when connected to a Mac over USB-C.

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/swift-5.9-orange)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

macOS recognises the M14t as an external display but does not provide its finger
touch controls. This driver maps finger taps and drags to mouse input, with
opt-in two-finger scrolling, pinch zoom and active pen support for the Gen 1 M14t.
It runs entirely in user space. Pinch zoom uses undocumented macOS gesture
event fields; other input uses Apple's public APIs.

This fork builds on [talesmousinho/m14t-touch-macos](https://github.com/talesmousinho/m14t-touch-macos).

No kernel extension. No system extension. No paid license.

---

## How it works

The M14t multiplexes two independent interfaces over the single USB-C cable:

```
USB-C cable
├── DisplayPort Alt Mode  →  video    →  handled natively by macOS ✅
└── USB HID Digitizer      →  touch    →  ignored by macOS, handled here ✅
```

The driver reads the HID digitizer stream and converts it to cursor events:

```
 ┌──────────────┐   raw X / Y / TipSwitch   ┌────────────────────┐
 │  M14t panel  │ ─────────────────────────▶│   HIDTouchDriver   │
 └──────────────┘     (IOHIDManager)         └─────────┬──────────┘
                                                       │
                          calibrated raw → screen px   │
                                            ┌──────────▼──────────┐
                                            │  CoordinateMapper    │  (pure, tested)
                                            └──────────┬──────────┘
                                                       │  CGPoint
                                            ┌──────────▼──────────┐
                                            │    MouseEmitter      │
                                            └──────────┬──────────┘
                                                       │  CGEvent
                                                       ▼
                                              macOS cursor / click
```

**Touch model** — a single contact maps directly to the left mouse button:

| Gesture | macOS event |
|---|---|
| Finger down | `leftMouseDown` |
| Finger moves while down | `leftMouseDragged` |
| Finger up | `leftMouseUp` |

A down-then-up without movement is a **click**; a down-move-up is a **drag**.
This remains the default. Add `--two-finger-scroll` to enable the Gen 1 gesture
mode described below.

---

## Project layout

The code is split by responsibility so each piece is small and, where it
matters, unit-testable:

| File | Responsibility |
|---|---|
| `main.swift` | Entry point: dispatch, permissions, run loop |
| `ArgumentParser.swift` | Pure CLI parsing → `TouchConfig` |
| `TouchConfig.swift` | Runtime options value type |
| `HIDTouchDriver.swift` | IOKit orchestration, calibration and event dispatch |
| `M14tReport.swift` | Gen 1 report decoding with separate contact IDs |
| `PenReport.swift` | Gen 1 pen report decoding and independent coordinate mapping |
| `PenInput.swift` | Pen hover, contact, button and proximity state |
| `TouchGestures.swift` | Pure tap, drag and two-finger scroll state machine |
| `CoordinateMapper.swift` | **Pure** raw→screen math (fully tested) |
| `Calibration.swift` | Calibration model + JSON persistence |
| `DisplayResolver.swift` | Display enumeration and selection |
| `MouseEmitter.swift` | `CGEvent` posting |
| `HIDUsage.swift` | Named HID usage constants |

The mapping math and argument parsing have no hardware or global-state
dependencies, so they're covered by `swift test` without a connected device.

---

## Requirements

- macOS 13 (Ventura) or later — Intel or Apple Silicon
- Xcode Command Line Tools: `xcode-select --install`
- The M14t connected via a **data-capable** USB-C cable

---

## Quick start

```bash
git clone https://github.com/bersoriano/m14t-touch-macos.git
cd m14t-touch-macos

# 1. Build
swift build -c release

# 2. Find which display index is your M14t
.build/release/m14ttouch --list

# 3. Calibrate once — touch all four corners firmly
.build/release/m14ttouch --display 1 --auto-calibrate

# 4. From now on, just run (calibration is remembered)
.build/release/m14ttouch --display 1
```

Or use the helper script, which builds and runs calibration interactively in the
terminal. Touch all four corners, then press Enter; the installer stops
calibration and returns the prompt. With `--autostart`, the driver then runs
silently via LaunchAgent, discards normal output, and writes errors to
`/tmp/m14ttouch.err.log`. The script installs a signed background app at `~/Applications/M14t Touch.app`
and a command-line symlink at `~/.local/bin/m14ttouch`. The LaunchAgent runs the
executable inside that app so you can grant permissions to a visible app:

```bash
./install.sh              # build + calibrate
./install.sh --autostart  # build + calibrate + run automatically at login
```

The installer bundles `Resources/Icons/M14tTouch-v2/M14tTouch.icns` before signing.
An icon change triggers a signed bundle update even when the executable is unchanged.

---

## Keeping touch on the M14t after display changes

`--display N` selects a display once, then tracks its UUID, hardware identity
(vendor, model and nonzero serial), and current bounds.
Moving displays in System Settings, changing the main display, or changing
resolution no longer redirects touch to another monitor. Active gestures are
cancelled on a layout change; lift all fingers before starting again. Input
pauses while the selected display is disconnected and resumes when it returns.

The installer saves both UUID and hardware identity in the login agent, so
selection survives restarts, display ordering changes, and USB reconnects that
change macOS's UUID. Recovery requires exactly one matching physical panel;
missing or ambiguous matches pause input. A monitor without a usable serial
continues to use UUID only. When upgrading an old index- or UUID-only agent,
run `--list` first, then reinstall using the M14t's **current**
index (for example, if it is now display 0):

```sh
DISPLAY_INDEX=0 ./install.sh --autostart --two-finger-scroll --skip-calibration
```

Include `--stylus` in reinstall commands if you use the active pen; installer
options replace the previous login agent's options.

For manual launches, use `--display-uuid UUID` with the identity printed by
`--list`. It takes precedence over `--display`. Add `--display-hardware-id V:M:S`
using the value from `--list` to retain physical matching across process restarts.
An unavailable target waits for that monitor; an invalid index exits instead of
falling back to the main display. `--print-display-uuid --display N` prints only
the selected UUID for scripts. `--print-display-hardware-id --display N` prints
its physical identity, or a blank line if its serial is unavailable.

## Two-finger scrolling (Gen 1, opt-in)

For the original 1920×1080 M14t with USB controller `2d1f:524c`, set the monitor's
OSD **Touch Support** to **Android/Chrome** for finger-only use, or **Windows**
when using the active pen. Turn **Auto rotation** off while calibrating. The
report parser is specific to this hardware; Gen 2 and other digitizers have not
been validated.

```bash
# Use the saved calibration; add --debug to inspect contacts and gestures.
.build/release/m14ttouch --display 1 --two-finger-scroll

# Keep calibration and enable this mode at login.
./install.sh --autostart --two-finger-scroll --skip-calibration
```

| Gesture | Behavior |
|---|---|
| One-finger tap | Left click |
| One-finger hold and move | Left drag after a 120 ms initial gesture delay |
| Two fingers moving together | Vertical or horizontal pixel scrolling |
| Lift one finger after scrolling | Suppress further input until both fingers lift |
| Three or more fingers | Ignore until all fingers lift |

Place both fingers together to scroll without an initial click. If a second
finger arrives after a drag has already begun, the driver releases that drag
before scrolling. Content follows finger motion, with scroll events anchored to
the gesture's starting point. Lift both fingers before beginning another gesture.
Add `--pinch-zoom` for zoom gestures and `--stylus` for Gen 1 active pen support
(see below). Two-finger right-click and momentum are not supported.

This mode decodes complete 40-byte `0x0c` reports containing five contact slots,
using each contact's ID and confidence bit. It ignores secondary digitizer and
pen reports unless `--stylus` is enabled, and releases any held mouse button on
disconnection or shutdown.

Run only one copy at a time. Before starting a manual debug session, stop the
login agent:

```bash
launchctl bootout "gui/$(id -u)/com.talesfonseca.m14ttouch"
```

Stop the manual process before restarting the login agent:

```bash
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.talesfonseca.m14ttouch.plist"
```

To return to default single-touch behavior while retaining calibration:

```bash
./install.sh --autostart --skip-calibration
```

`--skip-calibration` requires an existing, nonempty `~/.m14ttouch.json`. Omit it
for the first installation. With `--autostart`, the installer stops the old login
agent before updating the binary or starting calibration, avoiding competing
input processes.

---

## Pinch zoom (Gen 1, opt-in)

`--pinch-zoom` enables two-finger scrolling plus native magnification events.
Spread two fingers to zoom in; bring them together to zoom out. Place both
fingers before moving. Small initial jitter is ignored, then the first clear
motion selects pinch or scroll until both fingers lift. Zoom stays anchored at
the pair's starting midpoint on the M14t. A pinch never clicks on release.

```bash
# Find the current M14t index with --list; replace 1 if needed.
DISPLAY_INDEX=1 ./install.sh --autostart --pinch-zoom --stylus --skip-calibration
```

This preserves saved finger calibration and enables zoom at login. Keep
**Windows** OSD mode when using `--stylus`. Existing Accessibility and Input
Monitoring permissions still apply to `~/Applications/M14t Touch.app`; a rebuilt
app may require refreshing those grants (see Permissions).

Zoom works in views that handle native macOS pinch gestures. An app or view that
does not support magnification may ignore the gesture. There is no automatic
keyboard-shortcut fallback, and this does not enable system-wide Accessibility
Zoom. Use `--debug` to see `magnify` actions when diagnosing app compatibility.
To disable pinch while retaining scrolling and pen support, reinstall with
`--autostart --two-finger-scroll --stylus --skip-calibration`.

The isolated emitter uses undocumented CGEvent gesture fields, documented by
[Mac Mouse Fix's TouchSimulator](https://github.com/noah-nuebling/mac-mouse-fix/blob/master/Helper/Core/Touch/TouchSimulator.m)
and the Calftrail Touch research it credits. Future macOS releases may change
this format. Replay checks validate gesture recognition, cancellation and
AppKit's interpretation of zoom-in, zoom-out and phase values without posting
test input. Physical testing on the connected Gen 1 M14t with macOS 27 also
confirmed both zoom directions, finger tap/drag, two-finger scrolling and pen
drawing with this mode enabled. Support still depends on the target app/view.

## Active stylus (Gen 1, opt-in)

Set the monitor's physical OSD **Touch Support** to **Windows**. Close the OSD,
then disconnect and reconnect the USB-C connection to the Mac. Wait for the
digitizer to reconnect before testing. On the tested Gen 1 panel, Android/Chrome
delivered finger reports but no active-pen reports; Windows mode delivered pen
hover, tip pressure, eraser and range-exit reports after reconnection. A pen
working in the monitor's own OSD does not prove that it is reporting to the host.

```sh
.build/release/m14ttouch --display 1 --two-finger-scroll --stylus
DISPLAY_INDEX=1 ./install.sh --autostart --two-finger-scroll --stylus --skip-calibration
```

Choose the M14t's current index from `--list`. Hover moves the pointer; tip
contact clicks or draws immediately. The lower barrel button holds right-click;
the upper button signals a tablet eraser to apps that support it. Pressure and
tilt are passed as native tablet fields, but application support varies.
Finger gestures are suppressed while the pen is near the glass. Lift resting
fingers before switching back to touch.

Stylus mode takes exclusive access to the matched `2d1f:524c` digitizer. This
prevents macOS from injecting competing native pen events between mapped drag
events, which otherwise interrupt continuous drawing in Apple Notes. Other
input devices are unaffected; stopping the process releases the digitizer.

Pen coordinates use the Gen 1 digitizer's separate factory range. Finger
calibration and any personal touch offset remain unchanged. Both input types
follow the same physical display and layout changes; interrupted pen strokes must
lift before resuming. Pen packets do not participate in finger auto-calibration.

The report layout and native tablet emission are adapted from this repository's
upstream `HIDReportParser` and `MouseEmitter`, checked against the connected
Gen 1 USB descriptor (`0x06` and `0x0B`: 18-byte input reports). Replay tests cover
parsing, pressure/tilt fields, held tablet-button state, contact transitions and
interruption. On a Gen 1 M14t in Windows mode with macOS 27, physical testing
confirmed pen hover/tap, window dragging, continuous Apple Notes drawing, and
finger tap/two-finger scrolling after moving the pen away. Pressure-sensitive
brush response and eraser behavior still depend on the application and have not
been validated in that test.

Changing the USB connection can change macOS's display UUID. Current installs
recover using the panel's saved hardware identity. Older UUID-only agents need
one reinstall with the current M14t `DISPLAY_INDEX` and
`--stylus --two-finger-scroll --skip-calibration` to enable this recovery while
retaining finger calibration. A display that is absent stays paused rather than
redirecting input to another monitor. Physical testing on this setup also
confirmed automatic finger and pen recovery after unplugging and reconnecting
USB-C, without restarting the agent.

The supplied Lenovo Digital Pen needs an AAAA battery, with its positive end
pointing toward the tip. If `--debug` shows finger frames but no `PEN` lines,
verify Windows mode and USB reconnection first, then check the battery.
Recalibrating cannot fix missing reports. See [Lenovo battery instructions](https://download.lenovo.com/pccbbs/pubs/yoga_7_14_16/html_en/EN/InstallTheAAAABattery.html).

## Permissions

macOS gates the two things this driver needs. Grant both once:

| Permission | Why | Where |
|---|---|---|
| **Input Monitoring** | Read raw HID touch data | System Settings → Privacy & Security → Input Monitoring |
| **Accessibility** | Post cursor / click events | System Settings → Privacy & Security → Accessibility |

For installer-based runs, add **`~/Applications/M14t Touch.app`** to both lists.
In the file chooser, press **Command-Shift-G** and enter `~/Applications/`.
Terminal or Codex permission alone can make an interactive launch work while the
login agent remains denied.

When upgrading from the old standalone binary installation, remove the old
`m14ttouch` permission entry and approve **M14t Touch.app**. Calibration is retained.
The installer replaces the old CLI file with a symlink and updates the existing
LaunchAgent. Use the current M14t display index (on a Mac where it is display 0):

```bash
DISPLAY_INDEX=0 ./install.sh --autostart --two-finger-scroll --skip-calibration
```

Include `--stylus` when retaining active pen support.

The installer checks that the LaunchAgent stays running and exits with an error
if startup fails. Permission failures do not cause a repeated restart loop. After
granting permissions, restart the installed agent without rebuilding:

```bash
launchctl kickstart -k "gui/$(id -u)/com.talesfonseca.m14ttouch"
```

The driver prompts for Accessibility automatically on first interactive run.
On some macOS versions, this permission appears as **Device Control and Data
Access**. An enabled stale entry can still deny access; remove it and re-add the
installed app before restarting the agent.

Local installations use ad-hoc signing by default. Reinstalling an unchanged build
preserves its signature; changed builds may require renewed permission. If you
have a signing certificate, set `SIGNING_IDENTITY` to its name when installing to
sign updates with the same identity. An app bundle or ad-hoc signature does not
automatically grant permissions or guarantee grants survive code changes.

---

## Calibration

The M14t's HID descriptor advertises a `0–32767` coordinate range but only
emits values in a much narrower band — so a naive mapping puts touches in the
wrong place. `--auto-calibrate` solves this by widening its known range as you
touch, then saving the result to `~/.m14ttouch.json`:

```json
{
  "xMax" : 12371,
  "xMin" : 1,
  "yMax" : 6959,
  "yMin" : 1
}
```

Subsequent launches load this automatically. If something changes:

```bash
m14ttouch --reset-calibration                 # wipe and start over
m14ttouch --display 1 --x-min 1 --x-max 12371 --y-min 1 --y-max 6959  # set by hand
m14ttouch --display 1 --invert-y              # fix a flipped axis
```

---

## All options

```
--display N          Initial display index (default: 1); then track selected panel
--display-uuid UUID  Preferred display UUID; overrides --display
--print-display-uuid Print selected display UUID and exit
--display-hardware-id V:M:S
                     Physical vendor:model:serial identity for reconnect recovery
--print-display-hardware-id
                     Print selected hardware identity (blank if unavailable)
--auto-calibrate     Learn the touch range, then persist it
--invert-x           Mirror the horizontal axis
--invert-y           Mirror the vertical axis
--x-min / --x-max    Manual raw X bounds (override saved calibration)
--y-min / --y-max    Manual raw Y bounds
--debug              Print every HID event and resulting action
--two-finger-scroll  Enable Gen 1 two-finger scrolling
--pinch-zoom         Enable native pinch zoom and two-finger scrolling
--stylus             Enable Gen 1 active pen input
--no-accessibility-prompt
                     Suppress the Accessibility prompt for LaunchAgents
--list               List connected displays and exit
--reset-calibration  Delete saved calibration and exit
--help, -h           Show help
```

---

## Testing

```bash
swift test
```

Covers the coordinate mapping (corners, center, clamping, axis inversion,
multi-display offsets, degenerate input), CLI parsing, report decoding and gesture
transitions. The gesture replay scenarios are shared with a dependency-free
runner for Command Line Tools installations that lack XCTest:

```bash
bash test-gestures.sh
```

Replay coverage includes stable display selection, rearrangement/resizing, reconnect
recovery, tap/drag timing, contact IDs and slot order, both scroll axes, pinch
direction and native event phases, finger lifts, malformed reports, palm
filtering, pen pressure/tilt, held tablet-button state, and cancellation. Replay tests
cannot establish real event delivery or app behavior; the physical validation
above records what was tested on the connected Gen 1 panel.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| No device detected | Replug USB-C; confirm the cable carries data, not just power; try `--debug` |
| Touch offset / wrong place | Re-run `--auto-calibrate` and touch all four corners |
| Vertically/horizontally flipped | Add `--invert-y` and/or `--invert-x` |
| Cursor doesn't move at all | Grant **Accessibility** permission |
| `--debug` shows nothing | Grant **Input Monitoring** permission |
| Accessibility prompt repeats | Re-run `./install.sh --autostart`; the LaunchAgent should use `--no-accessibility-prompt` |
| Autostart installs but driver is not running | Remove/re-add **Accessibility** for `~/Applications/M14t Touch.app`, then run `launchctl kickstart -k "gui/$(id -u)/com.talesfonseca.m14ttouch"` |
| Works in Terminal, stops after closing it | Use `./install.sh --autostart` |
| Cursor jumps or windows flicker | Stop extra manual copies; run only one driver instance |
| Pen works in monitor menu but not on Mac | Set OSD Touch Support to **Windows**, close the menu, reconnect USB-C, and run with `--stylus` |
| Pinch does nothing | Enable `--pinch-zoom`, place both fingers before moving, and test a view that supports trackpad pinch. Lift both fingers between attempts; an established scroll stays a scroll |
| Notes draws dots instead of continuous pen strokes | Use the current `--stylus` build: it holds the tablet button during drags and takes exclusive M14t access to prevent competing native events |
| Input stops after changing USB connection | Upgrade UUID-only agents once with current M14t `DISPLAY_INDEX` and `--stylus --two-finger-scroll --skip-calibration`. Current installer saves physical identity for automatic recovery; unavailable or ambiguous identities stay paused |

---

## Scope & roadmap

Single-touch click/drag is the default. Gen 1 two-finger scrolling and pinch
zoom are opt-in modes; other multi-finger gestures remain out of scope.

- [x] Single-touch → click / drag
- [x] Auto-calibration with persistence
- [x] Multi-display support, axis inversion
- [x] Unit-tested coordinate mapping
- [x] Opt-in two-finger scroll (Gen 1)
- [x] Opt-in pinch zoom in supporting apps (Gen 1)
- [ ] Two-finger tap → right-click
- [ ] Menu-bar status app

---

## Why this exists

Built to avoid a $171 license for a feature that's really just "read HID, post
CGEvent." It's also a compact example of bridging a raw USB HID device to the
macOS event system in pure Swift — calibration, coordinate mapping, IOKit
callbacks, and synthetic input, with the tricky math isolated and tested.

## License

[MIT](LICENSE) — do whatever you want with it.
