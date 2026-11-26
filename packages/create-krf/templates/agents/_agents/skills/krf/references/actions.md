# Actions

An Action is anything a character does: casting a Fireball, dashing, blocking, opening a door, sitting in a seat or picking up an item. Its definition declares who can do it, what it costs, what it conflicts with and which Tags it applies. Its callbacks hold the behavior. The server runs every Action, whether a player or server code requests it.

## Generate it

Pick the recipe that matches how the Action ends:

| Recipe | Ends | Example |
| --- | --- | --- |
| `instant` | Right after `onStart` | Fireball, opening a door |
| `channel` | After `--duration` seconds | A two-second cast |
| `held` | When the player releases the input | Block, carrying an object |
| `toggle` | When the player presses the input again | Sitting in a seat, a stance |

```bash
npm run createAction -- --name Fireball --recipe instant --cost Mana=20 --requestable --yes --json
```

Declare the rest with flags, too:

- `--required-tag` and `--blocked-tag` for Tag gates.
- `--requirement` and `--cost` for Resource gates and prices.
- `--active-tag` and `--applied-tag` for Tags on the caster.
- `--lock` and `--interruptible-by` for conflicts.
- `--hook` for extra callback stubs.

Pass `--requestable` when players trigger the Action. See [action-input.md](action-input.md) for the request, its payload and its input binding.

For every flag, its syntax and default, and how to read the result, see [generators.md](generators.md#createaction).

## Fill in the callbacks

The generated module is a factory. KRF calls it once for each activation, so locals inside the factory belong to that one use of the Action:

```lua
function Fireball(): KRF.ActionDefinition
	return {
		id = "Fireball",
		visibility = "ClientVisible",
		costs = { Mana = 20 },
		onStart = function(context: KRF.ActionExecutionContext): ()
			launchFireball(context.actor, context.parameters)
			context:End()
		end,
	}
end
```

- `context.actor` is the caster, and `context.parameters` is the request payload. See [action-input.md](action-input.md) for validating it.
- Returning from `onStart` doesn't end the Action. Call `context:End()` when it's done, or `context:Interrupt(reason)` to cancel it.
- `onStopRequested` runs when a Stop is requested, such as when a held input is released. It decides whether to end; a Stop doesn't end the Action by itself.
- Keep the factory free of side effects. KRF also calls it at startup to validate the definition.
- Put game-specific start rules in `onCanStart`, returning `false, reason` to reject.

## Give players access

`--auto-grant` gives the Action to every Actor. For an Action players earn, such as an unlocked spell or a door only some players can open, leave it off and grant it from a source the game names:

```lua
local actions = actor:GetController("ActionController") :: KRF.ActionController
local granted: boolean, reason: string? = actions:SetGrants("Class", { "Fireball", "Blink" })
```

Each call replaces that source's whole set. The Actor can use every Action granted by any source, so clearing the Class set doesn't remove an Action that equipment also grants. Removing a grant stops future uses but doesn't cancel one that's running.

## Gate and price the start

KRF checks everything before the Action starts: grant, Tag gates, Resource requirements, costs, `onCanStart` and locks. If any check fails, nothing is spent and no activation exists.

Put prices in `costs`, never in a `Spend` call inside a callback. KRF doesn't undo changes your callbacks make when a later check rejects the start. Costs are paid once when the Action starts and are never refunded.

Gates are checked only at the start. If the caster gets Stunned while channeling, the Action keeps running until something interrupts it. See [Interrupt an Action](#interrupt-an-action).

## Put Tags on the caster

`activeTags` apply while the Action runs and are removed when it ends or is interrupted, such as Casting or Blocking. `appliedTags` outlive the Action and follow their own duration, such as a speed boost after a dash. Both apply only to the caster. To put a Tag on a target, see [tags.md](tags.md).

## Prevent conflicting Actions

Actions that share a lock name can't run at the same time:

```bash
npm run createAction -- --name Guard --recipe held --lock Stance --active-tag Blocking --interruptible-by Dodge --requestable --yes --json
```

A Dodge holding the `Stance` lock can now interrupt Guard, because Guard lists it in `--interruptible-by`. Without that, Dodge would be rejected while Guard runs.

The same Action can run several times at once unless a lock prevents it. Give an Action a lock when only one use should be active.

## Interrupt an Action

An interrupt cancels an Action before it finishes. Every interrupt carries a reason, and the Action finishes through `onInterrupt(context, reason)` instead of `onEnd`.

| Interrupted by | How | Reason |
| --- | --- | --- |
| The Action itself | `context:Interrupt(reason)` | Yours |
| Other server code | `actions:InterruptAction(sequenceId, reason)` | Yours |
| An incoming Action that takes its lock | `--interruptible-by` on the running Action | `ActionLockPreempted` |
| The player | `--allow-input-interrupt`, or leaving the game with `--on-disconnect Interrupt` | The input's reason |
| A failing callback | An error in `onStart`, or an error or yield in `onUpdate` | `ActionStartFailed`, `ActionUpdateFailed` |
| The Actor ending | Death, respawn or unregistering | `ActionControllerDestroyed` |

Nothing interrupts an Action because of a status. To make a stun cancel a channel, listen for the Tag when the Action starts, and disconnect when it finishes. Don't poll `HasTag` in `onUpdate`. An event costs nothing until the stun actually happens.

```lua
function ChannelHeal(): KRF.ActionDefinition
	local stunConnection: KRF.Connection? = nil

	local function disconnectStun(): ()
		if stunConnection ~= nil then
			stunConnection:Disconnect()
			stunConnection = nil
		end
	end

	return {
		id = "ChannelHeal",
		visibility = "ClientVisible",
		blockedTags = { "Stunned" },
		onStart = function(context: KRF.ActionExecutionContext): ()
			local tags = context.actor:GetController("TagController") :: KRF.TagController

			stunConnection = tags.OnTagAdded:Connect(function(_actor: KRF.Actor, tagId: string): ()
				if tagId == "Stunned" then
					context:Interrupt("Stunned")
				end
			end)
		end,
		onEnd = function(_context: KRF.ActionExecutionContext): ()
			disconnectStun()
		end,
		onInterrupt = function(_context: KRF.ActionExecutionContext, _reason: string): ()
			disconnectStun()
		end,
	}
end
```

`blockedTags` covers a caster who is already stunned when the Action starts. The listener covers a stun that lands while it runs.

For a rule that covers many Actions, such as "a stun interrupts everything", server code has to interrupt each running activation by its sequence ID. ActionController has no query for running activations, so record sequence IDs from `OnActionStarted` and forget them on `OnActionEnded` and `OnActionInterrupted`.

Use `onInterrupt` for anything that should differ from a normal finish:

- Costs are never refunded. If an interrupted cast should give Mana back, `Restore` it in `onInterrupt`.
- Branch on `reason` when a stun and a player cancel should behave differently.
- Use `canBeInterruptedBy` to refuse a lock preemption at runtime, such as a cast that can't be interrupted in its last half second.

## Run work over time

`onUpdate(context, deltaTime)` runs up to 20 times a second while the Action is active. `deltaTime` is the real time since this activation's last update, so multiply rates by it. Use it for channels, drains and anything that scales with time.

Never yield in `onUpdate`, `onCanStart`, `onEnd` or `onInterrupt`. A yield or error in `onUpdate` interrupts the Action. Only `onStart` may wait, and KRF cancels it when the Action ends.

## Clean up what you start

KRF releases the Action's locks, active Tags and updates by itself. Anything else the Action starts, such as a spawned task, a connection or a projectile, is the game's to clean up. Do it in both `onEnd` and `onInterrupt`, since an activation finishes through exactly one of them. After any call that can run other gameplay, check `context:IsActive()` before continuing.

## Start Actions from server code

NPC behavior and other server code start Actions directly, through the same checks a player's request goes through:

```lua
local result: KRF.ActionRequestResult = actions:RequestAction("Fireball", { Direction = direction })

if not result.accepted then
	warn(`Fireball rejected: {result.reason}`)
end
```

`result.sequenceId` identifies that one activation for `RequestStop`, `EndAction` or `InterruptAction`.

## React to Actions

ActionController fires `OnActionStarted`, `OnActionEnded` and `OnActionInterrupted` with the Actor, Action ID and sequence ID, plus the reason for an interrupt. `OnActionGrantChanged` fires when access changes. Clients see running `ClientVisible` Actions through the Actor's ActionsView; see [client-views.md](client-views.md).

## Exact APIs

- [Actions guide](docs/actions/guide.md) and [Actions API](docs/actions/api.md): definition fields, callback contracts, cost formulas and rejection reasons.

## Related references

- [action-input.md](action-input.md) for player requests, payloads and keybinds.
- [resources.md](resources.md) for costs, cooldowns and charges.
- [tags.md](tags.md) for Tag gates and putting Tags on targets.
- [client-views.md](client-views.md) for showing running Actions in the client UI.
