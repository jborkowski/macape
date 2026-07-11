# Plan: Fix Stuck Modifier After Cmd+E (Space Gets Cmd)

**Status:** Implemented — 2026-07-11  
**Date:** 2026-07-11  
**Symptom:** After using home-row Cmd+E (`A` held as Cmd, tap `E`), modifier sticks. Pressing Space afterward emits Cmd+Space (or modifier bleeds onto the next key).

---

## Problem Statement

macape maps home-row keys (`A` = Cmd) to virtual modifiers via `CGEvent.flags` OR — it never posts real modifier key-down/up pairs. The user reports that after a Cmd+E chord, the Cmd modifier stays latched internally, and the next Space press carries that Cmd flag.

The README promises automatic stuck-key recovery (`max_modifier_hold_ms`, physical-key desync detection, `clearStuck` IPC). That recovery code exists and has unit tests, but **does not run in production** once a key is in `.modifier` state with no `.pending` keys.

---

## Root Cause Analysis

### RC-1: Deadline timer stops after modifier promotion (PRIMARY)

`TimeWheel.nextDeadlineMach` only considers keys in `.pending` state:

```
keys.filter { $0.state == .pending && $0.deadlineMach > 0 }
```

Once `A` promotes to `.modifier`, no timer is scheduled. `Pipeline.advanceTime` (which runs stuck recovery) is **only** invoked from `Engine.fireDeadlineTimer`. Result: if `A`'s key-up is lost, `A` stays `.modifier` forever and `activeModifiers` keeps OR-ing Cmd onto every event.

**Affected files:**
- `Sources/MacapeCore/TimeWheel.swift` — `nextDeadlineMach`, `rescheduleNextDeadline`
- `Sources/MacapeCore/Engine.swift` — `rescheduleDeadlineTimer`, `fireDeadlineTimer`

### RC-2: Space tap synthesizes with stuck synthetic modifiers (SYMPTOM AMPLIFIER)

Tier 3 Space release (when layer was not consumed) posts a synthetic Space tap using `TimeWheel.activeModifiers(snapshot.keys)` — not just real physical modifiers. Layer arrows already strip synthetic mods (`userMods` only); Space tap does not. Stuck Cmd → Cmd+Space on release.

**Affected file:**
- `Sources/MacapeCore/Pipeline.swift` — Tier 3, lines ~125–127

### RC-3: Tier 5 bypasses state cleanup (SECONDARY EDGE CASE)

When a real physical modifier is held (`userMods` non-empty) and the event targets a home-row key, Tier 5 passes through without updating home-row state. An `A` key-up in this path does not clear `.modifier` state.

**Affected file:**
- `Sources/MacapeCore/Pipeline.swift` — Tier 5, lines ~153–156

---

## Failure Sequence (Repro)

| Step | User action        | Internal state after | Visible behavior        |
|------|--------------------|----------------------|-------------------------|
| 1    | `A` down           | `A` → `.pending`     | swallowed               |
| 2    | hold past deadline | `A` → `.modifier`    | Cmd active (synthetic)  |
| 3    | `E` down           | passthrough + Cmd    | Cmd+E works             |
| 4    | `E` up             | passthrough + Cmd    | normal                  |
| 5    | `A` up **lost**    | `A` stays `.modifier`| **Cmd stuck**           |
| 6    | Space down         | layer mode           | swallowed               |
| 7    | Space up           | synth Space + Cmd    | **Cmd+Space** ← bug    |

Common triggers for lost key-up: event tap timeout/disable, sleep/wake, rapid chord timing.

---

## Fix Strategy

Three layers, ordered by impact:

1. **Make recovery actually run** — schedule watchdog timer while modifiers are live; opportunistic desync check on every key event.
2. **Stop Space from inheriting synthetic mods** — align Space tap with layer-arrow behavior.
3. **Clear state on Tier 5 home-row key-up** — prevent stuck state when real modifiers are held.

---

## Implementation Plan

### Phase 1: Modifier watchdog timer (PRIMARY — RC-1)

**Goal:** Ensure `Pipeline.advanceTime` runs periodically while any home-row key is in `.modifier` state.

#### 1.1 Extend `TimeWheel.nextDeadlineMach`

**File:** `Sources/MacapeCore/TimeWheel.swift`

Change signature to accept `maxModifierHoldMs` and `nowMach`. Return the minimum of:

- Existing: earliest `.pending` key `deadlineMach`
- **New:** `nowMach + 50ms` when any key is `.modifier` (desync poll interval)
- **New:** `modifierSinceMach + maxModifierHoldMs` for each `.modifier` key (max-hold timeout)

Add helper:

```swift
public static func anyModifier(_ keys: [HRKey]) -> Bool
```

#### 1.2 Thread config through reschedule path

**File:** `Sources/MacapeCore/TimeWheel.swift`

Update `rescheduleNextDeadline` to accept `maxModifierHoldMs` and pass it to `nextDeadlineMach`.

**File:** `Sources/MacapeCore/Engine.swift`

Update `rescheduleDeadlineTimer` to pass `config.maxModifierHoldMs`.

#### 1.3 Opportunistic desync check on every key event

**File:** `Sources/MacapeCore/Engine.swift` — `handle(type:event:)`

After `Pipeline.process`, if `TimeWheel.anyModifier(snapshot.keys)`:

- Run physical-key desync check (extract from `advanceTime` or call a slim `Pipeline.checkModifierDesync(...)`)
- Apply recovery actions and reschedule timer

This catches stuck state on the **next keypress** (e.g. Space) without waiting for the 50ms poll.

**Alternative considered:** Only the timer poll. Rejected — next-keypress check gives faster recovery and is cheaper than relying solely on polling.

---

### Phase 2: Strip synthetic mods from Space tap (RC-2)

**Goal:** Space release without layer consumption should not carry home-row synthetic modifiers.

**File:** `Sources/MacapeCore/Pipeline.swift` — Tier 3

Change Space tap synthesis from:

```swift
let mods = TimeWheel.activeModifiers(snapshot.keys)
```

To:

```swift
let mods = userMods  // real physical modifiers only, same as layer arrows
```

**Behavior change:** `A(cmd held) + Space tap` → plain Space, not Cmd+Space. Matches README intent for layer behavior. Users who want Cmd+Space must hold a real Cmd key.

---

### Phase 3: Tier 5 home-row key-up cleanup (RC-3)

**Goal:** When a home-row key is released while real physical modifiers are held, clear its virtual state.

**File:** `Sources/MacapeCore/Pipeline.swift` — Tier 5

On `!down` (key-up) for a home-row key with non-idle state, call `clearHomeRowState` before pass-through.

---

### Phase 4: Regression tests

**File:** `Tests/MacapeCoreTests/StateMachineTests.swift` (and/or new `StuckModifierTests.swift`)

| Test name | Asserts |
|-----------|---------|
| `testNextDeadlineMachIncludesModifierWatchdog` | After `A` promotes to `.modifier` with no pending keys, `nextDeadlineMach` returns a future mach time (not nil) |
| `testModifierDesyncRecoversViaTimerWithoutPendingKeys` | `A` in `.modifier`, `keyIsPhysicallyDown(A) == false`, timer tick → `.idle` + `stuckRecovery` |
| `testModifierDesyncRecoversOnNextKeyEvent` | Simulate lost `A` up; next unrelated key event triggers desync recovery |
| `testCmdEThenSpaceDoesNotEmitCmdSpace` | Full happy path `A↓ E↓ E↑ A↑ Space↓ Space↑` → Space actions have no `.maskCommand` |
| `testCmdEThenLostAUpSpaceDoesNotStick` | `A↓ E↓ E↑` (no `A↑`) → Space or timer clears stuck Cmd before/at Space up |
| `testTier5HomeRowUpClearsModifierState` | `A` in `.modifier`, `A↑` with real Cmd held → state cleared |

**File:** `Tests/MacapeCoreTests/EngineTimingE2ETests.swift`

| Test name | Asserts |
|-----------|---------|
| `testModifierWatchdogFiresAfterPromotionWithNoMoreEvents` | Promote via `advanceTime`, reschedule timer, fire timer → desync check runs |

---

### Phase 5: Manual verification

```bash
# Run tests
swift test

# Rebuild and restart daemon
pkill macape 2>/dev/null; swift run macape

# Exercise repro:
#   1. Hold A (home-row Cmd) past hold threshold
#   2. Tap E, release E, release A
#   3. Tap Space — should be plain Space, not Cmd+Space
#   4. Repeat rapidly 10x — no stuck modifier

# Check logs for recovery events
log stream --predicate 'subsystem CONTAINS "macape"' --level debug

# Emergency manual recovery (existing)
echo '{"command":"clearStuck"}' | nc -U ~/.config/macape/macape.sock
```

---

## Files to Touch

| File | Change |
|------|--------|
| `Sources/MacapeCore/TimeWheel.swift` | Watchdog deadline, `anyModifier` helper |
| `Sources/MacapeCore/Engine.swift` | Pass `maxModifierHoldMs`; opportunistic desync check |
| `Sources/MacapeCore/Pipeline.swift` | Space tap flags; Tier 5 key-up cleanup; optional `checkModifierDesync` extract |
| `Tests/MacapeCoreTests/StateMachineTests.swift` | New regression tests |
| `Tests/MacapeCoreTests/EngineTimingE2ETests.swift` | Timer watchdog E2E test |
| `README.md` | Update Space behavior note if needed (optional, post-fix) |

**Estimated diff size:** ~60–80 lines production code, ~120 lines tests.

---

## Out of Scope

- Changing hold timeout defaults
- Real modifier key-down/up synthesis (large architectural change)
- Left/right Cmd distinction
- Karabiner-style per-app overrides

---

## Rollback / Risk

| Risk | Mitigation |
|------|------------|
| 50ms poll adds timer churn while modifier held | One-shot timer reschedules only while `.modifier` active; cancelled on idle |
| Space no longer gets synthetic Cmd | Intentional; matches layer-arrow semantics; real Cmd still works |
| Opportunistic desync false positive | Uses same `CGEventSource.keyState` check already tested in `testModifierStuckRecoveryOnPhysicalKeyUpDesync` |

Rollback: revert the three source files; no config migration needed.

---

## Success Criteria

- [x] `swift test` passes with all new tests green
- [ ] Cmd+E → Space manual repro no longer produces Cmd+Space
- [ ] Rapid Cmd+E chords (10x) do not leave stuck modifier
- [ ] `stuckRecoveries` metric increments when recovery fires (visible via `macape --stats`)
- [x] Existing Cmd+E buffer/passthrough tests still pass unchanged

---

## Work Order

1. Write tests for RC-1 (watchdog timer) — expect fail on current code
2. Implement Phase 1
3. Write tests for RC-2 (Space tap) — expect fail
4. Implement Phase 2
5. Implement Phase 3 + tests
6. Manual verification (Phase 5)
7. Optional README tweak

**Do not merge without all success criteria checked.**
