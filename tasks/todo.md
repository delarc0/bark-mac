# Notch island (Dynamic Island) for Bark

Design locked over several mock iterations. Chin (narrow) shape, state language
matches the shipped pill: red REC dot + live bars (recording), lime spinner
(transcribing), spinner + % (downloading). Idle = invisible (bare notch).

## Plan

- [ ] AppSettings: `notchIslandEnabled` Bool, default true. Auto behavior with a
      "force pill" override. Only has effect on a Mac that has a notch.
- [ ] `NotchGeometry`: detect the built-in notched screen + notch width/height
      from `safeAreaInsets` / `auxiliaryTop{Left,Right}Area`. Returns nil when no
      notched screen is active (clamshell, external-only, non-notch Macs).
- [ ] Extract shared indicators (BarkPalette, EQBars, Spinner, PulseDot) to
      `Indicators.swift` so pill + island share one visual vocabulary.
- [ ] `IslandView`: the chin island. Black, rounded-bottom, content in the chin
      below the camera line. Same states as the pill.
- [ ] `OverlayController`: add island panel; route reveal to island when the
      pointer's screen is notched AND notchIslandEnabled, else the pill. Decide
      the surface once per session; position island top-center of the notch.
- [ ] SettingsView: "Use the notch when available" toggle in General.
- [ ] Harness-verify IslandView renders all three states correctly.
- [ ] Build + install locally.

## Known verification limit

Erik is docked in clamshell (no active built-in display), so the REAL notch
fusion + placement cannot be pixel-verified on his machine right now. The
IslandView itself is verified in the harness; geometry resolves at runtime from
the live screen. A synthetic-notch debug path lets us verify placement mechanics
on an external display. Final on-notch check happens when the lid is next open.

## Review

Built 2026-07-19. All planned items done, app compiles + installed (Bark Dev).
- New files: `Indicators.swift` (shared BarkPalette/EQBars/Spinner/PulseDot),
  `NotchGeometry.swift`, `IslandView.swift`. `OverlayController` now owns two
  panels (pill + island), routes per session via `resolveSurface()`, positions
  the island top-center of the notched screen.
- Setting `notchIslandEnabled` (default true) + General toggle "Use the notch
  when available", disabled when the overlay is off.
- IslandView pixel-verified in scratchpad/island-harness across all 3 states:
  chin shape, content below the notch line, red dot + bars / spinner / spinner+%.
- Pill unchanged in behavior (indicators just moved to the shared file); main app
  BUILD SUCCEEDED confirms no regression.

### Outstanding (needs Erik + lid open)
- Real-notch fusion + placement NOT verified: Erik is clamshell, so no built-in
  display is active and the island can't render on his machine yet. Verify on
  the built-in when the lid is next open (dictate on the built-in screen).
- Reveal is a fade, not the spring "grow from the notch". Polish candidate.
- Content fit assumes notch width comfortably exceeds ~60pt (true on 14"/16").
  Confirm on the real notch.
