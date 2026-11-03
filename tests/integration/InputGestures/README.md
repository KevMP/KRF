# Testing input gestures in Studio

From the repository root, run:

```sh
npm run input:manual
```

This builds `build/input-gestures/Input-Gestures-Manual.rbxl`. Open that file in
Studio and press **Play (F5)**. Use Play rather than Run: the controls
belong to the local player. The place starts the real KRF server and client.

Click inside the game viewport. Use **Q**, the **right mouse button**, **gamepad
R2**, or the **PRESS / HOLD HERE** pad. The pad uses a native IAS UIButton binding
and works with mouse and touch; there is no scripted input normalizer. Right
mouse avoids treating clicks on the fixture's configuration buttons as input.

The control and diagnostic panes scroll independently. The live log distinguishes
native primitive events (`I#`) from public gesture events (`G#`). The candidate
display uses a framework-private diagnostic observer to show ordering and routing
eligibility. This fixture does not start Actions.

| Try | Expected result |
| --- | --- |
| Brief press and genuine release | Tap when the duration is at most the displayed Tap window. |
| Hold past 0.5s, then 1s | One Held, then one LongHeld, without another physical transition. |
| Double tap in PreferSpecific | The first Tap is immediate. Press two recognizes DoubleTapped before Pressed in the candidate list. Its short release still publishes Tap, marked ineligible for a new Action start. |
| Double tap in Independent | Both second-press candidates and the second-release Tap remain eligible. |
| One Tap in DeferredTap | No immediate Tap. One Tap appears strictly after the 0.5s release-to-press gap closes. |
| Double tap in DeferredTap | DoubleTapped appears on press two; the paired first and second Taps are suppressed. Native Pressed and Released remain immediate. |
| Enable the overlap window, then release after Held but before 0.75s | Held and Tap both appear. Enable same-source hold suppression to omit that Tap. |
| Hold Q while disabling the context | Cancelled, without Tap or catch-up holds. Enable again, release to neutral, then make a fresh press. |
| Hold Q while rebinding to E | The old epoch is cancelled. Other device slots stay installed; a held control cannot complete recognition on the replacement binding. |
| Reapply an identical source while held | Unchanged recognition and pending thresholds continue. |
| Remove gestures during a pending deferred gap | No delayed completion. Primitive input remains active. Reinstalling while held starts recognition on the next press. |
| Reset recognition between two taps | The old first tap cannot complete DoubleTapped. Reset itself emits no gesture or primitive event. |
| Combine keyboard, gamepad, and pad bindings | IAS supplies one logical Bool epoch; duplicate device notifications must not produce extra recognition. |

Thresholds compare I1's dispatch timestamps, not unknowable physical hardware
times. Under a Studio stall, timers may report late actual emission times; holds
still catch up on genuine release. Cancellation retires pending work immediately.
Use deterministic unit tests for exact inclusive-boundary checks.

The build command does not launch or control Studio. You can also build directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-input-gestures-manual.ps1
```

Run the automated two-client native IAS/Scriptable fixture separately:

```sh
npm run test:integration:i2
```

That fixture checks real initialization, native Bool transitions, timed gestures,
context cancellation, public delivery, local ownership, and teardown. Exact
timing boundaries, stale wakeups, commit faults, and prepared recognition resets
are covered by the injected-clock unit tests.
