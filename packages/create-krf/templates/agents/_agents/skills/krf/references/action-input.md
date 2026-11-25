# Action requests, input routes and controls

Players start Actions from the client, but the server still decides whether each one runs. Three pieces connect a key press to an Action:

- **A request entry**, shared by server and client, declares that clients may request the Action and what data they may send with it.
- **An input policy** on the client decides how the input drives the Action's lifetime: a single press, held down, or toggled.
- **Controls** on the client bind keys and buttons to inputs, and route those inputs to Actions.

A request never grants the Action or skips its costs, Tags, locks or `onCanStart`. The server checks all of them exactly as it does for server code.

## Make an Action requestable

Pass `--requestable` with the recipe that matches the input:

```bash
npm run --silent createAction -- --name Guard --recipe held --lock Stance --active-tag Blocking --requestable --yes --json
```

The generator writes up to three files. Read its result for the exact paths:

- the server Action in `src/server/Actions`;
- the request entry in `src/shared/ActionRequests`;
- for held, toggle or Actions with a payload, the input policy in `src/client/ActionInputPolicies`.

It doesn't bind a key. See [Bind a key](#bind-a-key).

## Choose how the input drives the Action

| Recipe | Policy | The input |
| --- | --- | --- |
| `instant`, `channel` | `OneShot` | Requests a start on each press |
| `held` | `WhileDown` | Requests a start on press and a stop on release |
| `toggle` | `Toggle` | Requests a start on one press and a stop on the next |

A stop request runs the Action's `onStopRequested`, which decides whether to end it. The generated held and toggle Actions end there. If the window loses focus or the controls change while a held Action runs, KRF interrupts it instead of pretending the key was released.

The policy belongs to the Action ID. An Action that should be held in one place and toggled in another needs two Actions.

## Bind a key

A generated game splits controls into two modules:

- `src/client/Controls/Keybinds.luau` declares inputs, such as `AbilitySlot1`, and the keys and buttons bound to each one.
- `src/client/Controls/Loadout.luau` routes each slot to the Action currently equipped in it.

To put Guard on a second key, add an input for the slot in `Keybinds.luau`:

```lua
AbilitySlot2 = {
	context = "Gameplay",
	type = Enum.InputActionType.Bool,
	bindings = {
		Keyboard = { keyCode = Enum.KeyCode.Q },
		Gamepad = { keyCode = Enum.KeyCode.ButtonY },
	},
},
```

Then add the slot to `SLOTS` in `Loadout.luau` and equip the Action in it:

```lua
local SLOTS: { string } = { "AbilitySlot1", "AbilitySlot2" }

local equipped: { [string]: string } = {
	AbilitySlot1 = "Focus",
	AbilitySlot2 = "Guard",
}
```

The Loadout resolves the slot when the key is pressed, so `Loadout.Equip("AbilitySlot2", "Dash")` changes what the key does without touching the bindings. A held Action still stops on release even if the slot changed while it was held.

Check the game's own controls first. If they differ from these modules, follow their structure.

## Recognize taps, holds, combos and custom patterns

A route can trigger on more than a plain press. Declare the pattern next to the inputs in `Keybinds.luau`, then route it to an Action in `Loadout.luau`. Use the simplest one that fits:

| Pattern | Declare it in | Route it with |
| --- | --- | --- |
| Tap, hold, long hold or double tap of one input | `gestures` | `{ kind = "Input", inputId = "...", gesture = "Held" }` |
| Several inputs in order, such as a combo | `sequences` | `{ kind = "Sequence", sequenceId = "..." }` |
| Any other rule, such as mashing a key | `recognizers` | `{ kind = "Custom", recognizerId = "..." }` |

### Gestures

```lua
gestures = {
	AbilitySlot1 = {
		Tap = { maxDurationSeconds = 0.2 },
		Held = { afterSeconds = 0.4 },
	},
},
```

A route on `"Pressed"` fires immediately. Route on `"Tap"` or `"Held"` when a quick press and a long press should do different things. A route that needs a held key, such as a `WhileDown` Action, can't use `"Tap"`, because a tap has already been released.

### Sequences

```lua
sequences = {
	Uppercut = {
		steps = { "Down", "Forward", "Attack" },
		maxGapSeconds = 0.3,
		maxTotalSeconds = 0.8,
	},
},
```

Both time limits are required. Pressing another of the sequence's own inputs out of order ends the attempt. Add inputs to `scope` when pressing them should end it too. A step can also be a gesture, such as `{ inputId = "Attack", kind = "Held" }`.

A sequence route wins over the plain press of its last key by default, so finishing Uppercut doesn't also fire whatever Attack is bound to. When one combo is the start of a longer one, put both in a `sequenceGroups` entry with `policy = "DeferredPrefix"`, so only the longer one fires when the player completes it. A result from such a group can't drive a `WhileDown` Action.

### Custom recognizers

Write a recognizer only when gestures and sequences can't express the rule. This one matches five presses within one second:

```lua
recognizers = {
	Mash = {
		inputs = { "Attack" },
		maxWindowSeconds = 1,
		onEvent = function(ctx, event)
			if event.kind ~= "Pressed" then
				return nil
			end

			local presses: number = ((ctx:GetState("presses") :: number?) or 0) + 1
			ctx:SetState("presses", if presses >= 5 then 0 else presses)

			return if presses >= 5 then {} else nil
		end,
	},
},
```

- Return `{}` (or `{ metadata = { ... } }`) for a match and `nil` otherwise.
- Keep state in `ctx:GetState` and `ctx:SetState`, not in locals outside the callback. KRF clears it when the window ends or controls are cancelled.
- The window starts at the first watched event and never extends. Reset your state after a match if the next press should start over.
- Never yield or error in a callback. Either one faults the recognizer, and it stops matching until its declaration is removed and added again. `KRF.InputRuntime.GetRecognizer(id)` reports a fault.
- Keep gameplay out of the recognizer. It only recognizes input; the Action it routes to does the work.

## Send data with the request

Declare each field the client sends with `--start-field`, or `--stop-field` for data sent on release:

```bash
npm run --silent createAction -- --name Fireball --cost Mana=20 --requestable --start-field "Target:Array(F32,3)" --yes --json
```

The generator adds the field to the request entry's schema and writes a `startParameters` producer in the input policy that returns a placeholder. Replace the placeholder with the real value. For aim, cast from the camera through the mouse:

```lua
startParameters = function(_context: KRF.ActionInputContext): { Target: { number } }
	local location: Vector2 = UserInputService:GetMouseLocation()
	local ray: Ray = workspace.CurrentCamera:ViewportPointToRay(location.X, location.Y)
	local hit: RaycastResult? = workspace:Raycast(ray.Origin, ray.Direction * 500)
	local target: Vector3 = if hit ~= nil then hit.Position else ray.Origin + ray.Direction * 500

	return { Target = { target.X, target.Y, target.Z } }
end,
```

Send the smallest claim the server can check, such as the point the player aimed at, rather than a result the server should work out itself, such as what was hit.

Run `npm run createAction -- --help` for every field type.

## Check the claim on the server

The schema checks the payload's shape. It can't tell whether the aim makes sense. Check that in `onCanStart`, so a bad claim is rejected before KRF spends anything:

```lua
local MAX_RANGE: number = 120

onCanStart = function(context: KRF.ActionStartContext): (boolean, string?)
	local target: { number } = (context.parameters :: { Target: { number } }).Target
	local model: Model? = context.actor.model
	local root: BasePart? = if model ~= nil then model.PrimaryPart else nil

	if root == nil then
		return false, "NoCharacter"
	end

	local distance: number = (Vector3.new(target[1], target[2], target[3]) - root.Position).Magnitude

	if distance ~= distance or distance > MAX_RANGE then
		return false, "TargetOutOfRange"
	end

	return true, nil
end,
```

Then work from the server's own state in `onStart`. Aim from the caster's position on the server, not one the client sent, and run hit detection on the server.

## Request from game code

For a UI button or any request that isn't a key binding, call ClientActionRuntime directly with the full payload:

```lua
local requestId: number?, reason: string? = KRF.ClientActionRuntime.RequestAction(actorView, "Fireball", { Target = { 0, 5, 0 } })
```

The returned ID means the client accepted the request locally, not that the server started the Action. Keep the ID to send a stop later with `RequestStop(requestId)`.

`ClientActionRuntime.OnActionRequest` reports what happened: accepted with the server's sequence ID, rejected with a reason, or `Unknown`. `Unknown` doesn't mean rejected. Never send the request again because of it, or the Action may run twice.

## Change controls together

`KRF.ClientControls.Apply` installs inputs, routes, enabled contexts and the controlled Actor in one call. The generated `Controls` module uses it. Use it when the changes depend on each other, such as a new key and the route that uses it, or switching control to another character. A call checks the whole result before installing anything, and a failed call changes nothing.

## Control other characters

A client can request Actions only for its own character by default. To let a player control another Actor, such as a summoned pet, pass `actionControlAuthority` to `Server.Init`. Choosing that Actor on the client doesn't give permission on its own.

## Exact APIs

- [Client Action requests](docs/actions/requests.md) and [Client Action API](docs/actions/client-api.md): request entries, policies, producers and request outcomes.
- [Action routes](docs/actions/routes.md): routes, gestures, sequences and what happens when controls change mid-press.
- [Controls guide](docs/controls/guide.md) and [Controls API](docs/controls/api.md): `ClientControls.Apply`.
- [Input guide](docs/input/guide.md) and [Input API](docs/input/api.md): input definitions, contexts and bindings.
- [Input recognition](docs/input/recognition.md) and [Recognition API](docs/input/recognition-api.md): gesture timing, sequence rules, deferred-prefix groups and recognizer limits.
- [Schemas API](docs/schemas/api.md): payload field types.

## Related references

- [actions.md](actions.md) for the server side of the Action.
- [client-views.md](client-views.md) for showing which Actions are running.
- [commands.md](commands.md) for client requests that aren't Actions.
