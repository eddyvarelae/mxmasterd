# mxmasterd

A driverless button & gesture daemon for the Logitech MX Master 3S — a small
Swift program that replaces the parts of Logi Options+ actually worth keeping.
It speaks Logitech's HID++ 2.0 protocol directly to the mouse over Bluetooth LE;
no Logitech software involved.

> Name note: `mxmasterd` follows the Unix daemon convention (the trailing `d`).
> It's a background service, not an "AI agent".

## Mapping

| Control | HID++ CID | Action |
|---|---|---|
| Thumb pad (gesture button) — tap | `0x00C3` | Mission Control |
| Thumb pad — hold + drag left/right | `0x00C3` (rawXY) | Switch desktop / Space |
| Mode button (below wheel) | `0x00C4` | Paste (⌘V) |
| Wheel click | `0x0052` | SmartShift clutch toggle (ratchet ↔ free-spin) |

Back/forward (`0x0053`/`0x0056`) are left as normal buttons 4/5.

## Live dashboard

The daemon runs a tiny localhost server at **http://localhost:8722** that shows,
in real time, which control you pressed, the gesture drag meter, and the action
fired — useful for demos and for explaining what the software does. It's a
single `dashboard.html`, served straight from the daemon over Server-Sent
Events.

## How it works

- The mouse (VID `0x046D`, PID `0xB034`, BLE) exposes a vendor channel using
  20-byte HID++ "long" reports (report ID `0x11`, device index `0xFF`).
- **Buttons** — feature `0x1B04` (Reprogrammable Controls v4) `setCidReporting`
  with flag `0x03` diverts a control; its presses then arrive as
  `divertedButtonsEvent` frames instead of normal clicks.
- **Gesture** — the thumb pad is diverted with flag `0x33` (divert + rawXY). The
  firmware freezes the cursor while the pad is held and streams movement as
  `divertedRawXYEvent` (event id `0x10`); the daemon accumulates horizontal
  travel and switches Spaces past a threshold.
- **Clutch** — feature `0x2110` (SmartShift) `setRatchetControlMode` commands the
  wheel's mechanical clutch (1 = free-spin, 2 = ratchet).
- Diverts are volatile (lost on power-cycle), so the daemon re-asserts them on
  device (re)arrival and every 60 s.

### Space switching note

macOS ignores **synthesized** Ctrl+arrow keystrokes for Space switching (an
anti-automation measure — synthetic keys still work for app shortcuts like ⌘V,
which is why paste works). The daemon therefore switches Spaces through the
private SkyLight API (`CGSManagedDisplaySetCurrentSpace`) rather than faking a
keystroke. Mission Control is launched the same way the OS does it
(`open -b com.apple.exposelauncher`) for the same reason.

## Build & install

```sh
swiftc -O -parse-as-library -o bin/mxmasterd src/mxmasterd.swift
cp com.varela.mxmasterd.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.varela.mxmasterd.plist
# after a rebuild:
launchctl kickstart -k gui/$UID/com.varela.mxmasterd
```

Logs: `~/Library/Logs/mxmasterd.log`. Set `MXDBG=1` in the environment for
verbose event/gesture tracing.

The binary needs two one-time grants in System Settings → Privacy & Security:
**Input Monitoring** (open the HID device) and **Accessibility** (post
keystrokes / control Spaces). Because the build is unsigned, replacing the
binary changes its hash and the grants must be re-approved — sign with a stable
identity to avoid this.

## Files

- `src/mxmasterd.swift` — the daemon (single file, no dependencies)
- `dashboard.html` — the live visualizer (served by the daemon)
- `com.varela.mxmasterd.plist` — launchd agent (RunAtLoad + KeepAlive)
- `tools/` — HID++ probe tools from development; `hidpp.swift` is the shared
  client. Build one with:
  `swiftc -parse-as-library -o tools/probe tools/hidpp.swift tools/probe.swift`

## Degraded mode (daemon not running)

Buttons revert to firmware defaults: thumb pad dead, mode button toggles the
clutch, wheel click is a middle click.
