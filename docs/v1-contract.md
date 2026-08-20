# IronLine — First Playable Contract

This document is the scope gate for the first playable. If another document conflicts with it, this one wins until the first playable is tested.

## Product thesis

**Do not gamify workout logging. Turn real physical performance into a verified competitive game.**

The camera is the referee. THE LINE is the opponent model. Friends become the multiplayer layer after the single-player proof works.

## First playable — required

One exercise only: **Incline Dumbbell Press**.

Flow:

1. User has a baseline target (hard-coded is acceptable for the first camera test).
2. User manually enters dumbbell weight.
3. User props phone side-on and starts a verified set.
4. Apple Vision detects shoulder/elbow/wrist geometry on-device.
5. A state machine counts only top -> full-depth -> top reps.
6. Shallow attempts resolve as **NO REP — INSUFFICIENT ROM**.
7. Ending the set calculates performance against THE LINE using the same Epley-based score as the backend.
8. UI resolves to **LINE BEATEN** or **LINE MISSED** with the % above/below expectation.

## Explicitly not required for first playable

- automatic weight recognition
- exercise auto-detection
- eight-exercise catalog
- crews
- social feed
- ELO
- Ghosts
- live spectating
- physique scanning
- AI trash talk
- Apple Sign-In
- video uploads / proof clips

These remain product backlog items; they are not allowed to delay the first camera + Line loop.

## Camera assumptions

- Back camera
- One athlete in frame
- Side view
- Upper body clearly visible
- Athlete occupies a meaningful portion of frame
- On-device processing only; no video leaves the phone

## Rep contract — incline dumbbell press prototype

The first implementation uses elbow angle as the observable signal:

- arm considered at top/lockout around **155°+**
- full depth reached around **100° or less**
- a rep counts only after the sequence top -> bottom -> top
- an attempt that meaningfully descends but returns to lockout without reaching bottom is a no-rep

These values are tuning constants, not product truth. Real gym footage decides the final thresholds.

## Success criteria

After 5 sessions each with two testers:

1. Do they immediately want to run it back?
2. Does the camera count agree with a human observer often enough to trust the game?
3. Do users accept the no-rep calls, or argue with them?
4. Does beating THE LINE create more tension than simply seeing reps logged?
5. Does anyone spontaneously ask to challenge someone else?

The first playable passes only if both **camera trust** and **competitive tension** exist.
