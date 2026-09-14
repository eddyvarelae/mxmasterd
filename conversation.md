# MX Master Custom Driver — Build Log

Logi Options+ kept breaking, so we threw it out and built its replacement: a
~300-line Swift daemon that speaks Logitech's proprietary HID++ protocol
directly to the mouse over Bluetooth. Thumb pad → Mission Control, hidden
button → paste, wheel-click → toggles the scroll wheel's physical clutch.
Built in one session with Claude Code.

---

## 1. My app is failing

> My logioptions+ app keeps failing, it's broken, any chance you can map the
> bottom button of my mxmaster to do the same action of the trackpad when I
> swipe up with 3 fingers?

Claude found the problem: Options+ was installed but its background agent —
the process that actually applies the button mappings — was dead, not even
registered with the system. It offered a repair, but I'd had enough:

> just FYI I already unistalled, plus I don't want to depend on an app,
> better to map it

New rule: **no Logitech software, no third-party apps.**

---

## 2. Mapping the buttons

I sent a diagram of the mouse with three buttons circled A, B, C:

> Now look at the last screenshot I took, I only care about A,B,C
> …the scroll wheel has a click as well, that one I'd like to change the feel
> of the scroll, the b should paste (CMD+V) and the thumb pad should do
> mission control

Claude wrote a Swift click-listener and ran capture rounds while I pressed
each button on cue. The verdict, button by button:

- **Thumb pad** — never talks to macOS at all. Its presses only exist inside
  Logitech's proprietary protocol.
- **B** — silent too: the mouse consumes it internally to shift the scroll
  wheel's clutch.
- **Wheel-click feel** — the clutch is a mechanical part. No macOS setting
  can reach it.

All three mappings were impossible natively. The driver wasn't optional —
someone had to speak Logitech's language to this mouse.

> can't you recreate the firmware/driver?

Yes. That's a thing we can do.

---

## 3. Speaking mouse

Logitech's HID++ protocol is reverse-engineered and documented by the Linux
community. Claude probed the mouse's hidden vendor channel — raw 20-byte
reports over Bluetooth:

- Ping → **protocol 4.5**, the mouse answers
- Feature dump → 35 features, including button diverting (`0x1B04`) and
  SmartShift, the clutch control (`0x2110`)
- Button table → thumb pad `0x00C3`, B `0x00C4`, wheel-click `0x0052`,
  all flagged **divertable**

Then the money test: Claude commanded the clutch **remotely** — my wheel
went clicky with nobody touching the mouse — and diverted all three buttons,
catching clean press events from each one.

---

## 4. Building the new app

`mxmasterd`: one Swift file, no dependencies. It diverts the three buttons,
listens for their events, and acts:

- Thumb pad → Mission Control
- B → synthesized ⌘V
- Wheel-click → flips the clutch (ratchet ↔ free-spin)

Live test:

> yes! except the thumbpad, it only scrolls up when I press it

The synthetic Ctrl+↑ reached apps as a bare arrow key. Fix: launch Mission
Control the way the OS itself does — `open -b com.apple.exposelauncher`.

> works!!

---

## 5. Making it permanent

Installed as a launchd agent: starts at login, restarts on crash, re-asserts
the button config every 60 s (the mouse forgets diverts when power-cycled).

Last boss: macOS privacy permissions for the new binary. I didn't know how to
grant Accessibility, so Claude scripted that too — opened the privacy pane,
clicked **+**, drove the file picker straight to the binary.

```
permissions: inputMonitoring=true accessibility=true
device matched
configured: diverts applied, ratchet mode=2
```

---

## 6. What shipped

- `mxmasterd` — ~300 lines of Swift, my own mouse driver, running 24/7
- Thumb pad, hidden button, and wheel-click doing things Logitech's own
  software crashed trying to do
- Zero Logitech software. Zero third-party apps. One afternoon.
