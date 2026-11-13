# Fire Actions manual place

A small game built against the current KRF source. The framework is unchanged.
The arena has one block dummy and server-created orange attack shapes. The text
panel reads public KRF views and request observations.

## Launch

From the repository root, with the repository's Rojo/toolchain installed:

```powershell
npm run demo:fire-actions
```

Open `KRF-Fire-Actions-Manual.rbxl` in Roblox Studio and press **Play (F5)**.
Use Play with a player, rather than Run. Click inside the game viewport before
using the keys; focused text boxes and Studio panels take keyboard input.
The panel should report `Actor: ready` and show the dummy's Tags.

No publishing, assets, credentials, plugins, or game-specific remotes are required.
The generated place is ignored by Git; rebuilding includes current framework edits.
Run `npm run typecheck:fire-actions` to check the example against this place's
Rojo tree. The repository's full `npm test` includes that check and example lint.

## Checks

| Input | Expected result |
| --- | --- |
| Hold F while facing the dummy | One Fire Breath Start, an active orange beam, `BreathingFire` on your Actor, and repeated server refreshes of the dummy's Burning Tag. |
| Release F | `GenuineRelease`, Stop admission/outcome, replicated Ended, beam cleanup, and removal of `BreathingFire`. Burning expires three seconds after the last hit. |
| Tap Q alone | One Start admission/outcome, an orange ball flying to the server-selected dummy, Burning on impact, and replicated Ended. Holding Q never repeats it. |
| Press X, Q, Z in order | Each gap must be under 0.6 seconds, with total time under 1.5 seconds. Only `FlameStrike` is requested: a yellow column appears, Burning refreshes, and Stunned expires after 1.5 seconds. No Q projectile appears. |
| Press X, Q and wait | Q is reserved while the longer combo is possible. The deferred short prefix requests exactly one Fireball after timeout. A wrong watched key also flushes this completed short prefix. |
| Press X and let the prefix expire before Q | Q is standalone again and fires once; no Flame Strike request. |
| Tap Q again while its projectile is active | The server rejects the overlapping Fireball because its Action lock is held. The request log distinguishes admission from rejection. |
| Hold F, focus another window, then return | Cancellation/Interrupt, rather than a genuine Stop. The beam and owned Tag clear; release F before pressing it again. |
| Reset your character, then wait for `ready` | The old Actor tears down and the new Actor gets its own grants, view, and controls. |

WASD and the camera use ordinary Roblox character controls.
Fire Breath checks the character's facing and a 28-stud beam. The other two
Actions select the fixed dummy on the server and reject starts beyond 40 studs.
The dummy becomes orange while Burning and yellow while Stunned. Its color,
label, and countdown use the client's replicated TagsView.

For a second observer, use Studio's **Server & Clients** test with two players.
Both clients should see the shared dummy Tags and server-created shapes. Each
request log belongs to that client's requests; replicated Action lifecycle
entries in the panel follow its own character. Studio Output includes the
server's lifecycle entries and the client's observation entries.

## Consumer wiring

- `server/Startup.server.luau` owns `Server.Init`, Actor registration/teardown,
  and per-character `ActionController:SetGrants`.
- `server/TagCatalog.luau` supplies visible Tag definitions through startup.
- `server/ActionCatalog.luau` supplies per-activation factories. Server hooks own
  hit checks, visuals, Stop/End/Interrupt decisions, and cleanup. The channel's
  active Tag uses declarative `activeTags`; target effects use the target's
  `TagController`.
- `shared/RequestSchemas.luau` is passed unchanged to server and client startup.
  Fire Breath permits Stop/Interrupt and disconnect interruption; its client
  policy is WhileDown. The one-shot Actions have no client release contract.
- `client/InputConfig.luau` declares native bindings, a `DeferredPrefix` group,
  policies, and routes. An immediate exclusive X-Q match selects no Action and
  reserves Q's primitive route; the deferred group then chooses X-Q's Fireball
  fallback or X-Q-Z's Flame Strike. No game-owned timer or combo state machine
  is needed. `ClientControls.Apply` installs the source/context and later binds
  the current character's profile and controlled Actor atomically.
- `client/Panel.luau` reads ActorView, ActionsView, TagsView, and the public
  `ClientActionRuntime.OnActionRequest` event. It does not decide gameplay or
  create effects from request acceptance.

There is no damage/Health model, prediction, or projectile framework here. A hit
applies Tags to make authority and replication observable. The server owns the
toy projectile; all factory hooks are non-yielding and use KRF's Action updates.
