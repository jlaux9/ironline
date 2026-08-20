# Phase 1 — First Gym Test Protocol

The goal of the first test is not to prove every exercise. It is to learn whether IronLine can make one set feel trustworthy and competitive.

## Setup

- Exercise: Incline Dumbbell Press only
- Phone: physical iPhone, portrait, back camera
- Position: side-on, 3–6 ft from lifter
- Frame: shoulder, elbow, wrist clearly visible throughout the rep
- Lighting: normal gym lighting; note any tracking failures
- Weight: manually entered
- LINE: prototype target is acceptable for this test

## Run

Each tester completes 5 sets across at least 2 sessions.

For every set, record:

- human-observed completed reps
- IronLine verified reps
- human-observed shallow/no-reps
- IronLine no-reps
- any tracking loss
- whether the user agrees with every no-rep call
- whether beating/missing THE LINE changed how hard they pushed

## Acceptance targets for the next iteration

These are product gates, not final launch metrics:

- Verified-rep count agrees with human observer on at least 90% of attempts in the controlled side-view setup.
- False no-reps are rare enough that neither tester loses trust in the referee.
- No ghost rep is created when the athlete enters frame mid-rep.
- A tracking loss never silently creates a verified rep.
- At least one tester voluntarily wants to run the challenge again without being asked.

## Tune before expanding

Only tune these first:

- `RepCounter.topAngle`
- `RepCounter.bottomAngle`
- `RepCounter.attemptDepth`
- `RepCounter.minimumConfidence`
- `AngleSmoother.windowSize`

Do not add another exercise until the incline dumbbell press loop is trustworthy.

## Data we actually care about

The winning question is not “did Vision detect a skeleton?”

It is:

**Did the camera make the result feel official enough that losing mattered?**
