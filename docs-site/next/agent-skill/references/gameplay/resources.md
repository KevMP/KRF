# Resources

KRF version: 0.2.0. Verify claims against the installed package before relying on them; see [Verify](#verify).

## Read this when

The task involves a per-Actor meter: stamina, mana, Qi, energy, ammo, heat, a cooldown, charges, or a HUD bar for one. Also read it when an Action costs or requires a meter, together with the Action costs reference.

Read a different reference instead when the value is:

| Value | Reference |
| --- | --- |
| A stat that buffs and debuffs modify, such as speed or max health | `tags-and-properties.md` |
| A status such as Stunned or Burning | `tags-and-properties.md` |
| Other replicated game state, such as a quest stage | `../networking/replication-domains.md` |

## Facts that change the code you write

- **The server owns Resources.** Clients cannot change them; there is no Resource remote. A client asks for gameplay through an Action request or a Command.
- **Definitions are catalog modules, not calls.** In a `create-krf` project, each module in `src/server/Resources` returns one `KRF.ResourceDefinition`, and the starter passes the folder to `Server.Init({ resources = ... })`. Never call `ResourceRegistry.Load`.
- **The current value is never a Property.** Properties may supply `min`, `max` and `regen.rate` through `{ propertyName = "..." }`. Every named Property must be registered in `src/server/Properties`.
- **Assignment is explicit.** An Actor has a Resource only via `autoAssign = true` or `ResourceController:AddResource`. There is no unassign.
- **Action payment is declarative.** Use the Action's `costs` and `resourceRequirements`. Never call `Spend` before `RequestAction` or inside `onCanStart`; a rejected Action would still have been charged.
- **Bounds clamp, they never refill.** Raising `max` leaves `current` unchanged.
- **Regeneration is automatic.** It runs every 0.1 s while `actor.enabled`, and a rate of 0 or less does nothing. Never call `ResourceController:Step` from game code.
- **Clients estimate regeneration locally.** The client `OnResourceChanged` does not fire for regeneration, so HUDs must read `GetResource`/`GetCurrent` every frame.
- **`ClientVisible` goes to every client that sees the Actor**, not only its owner. Use `ServerOnly` for private values.

## Choose the API

| Intent | Code |
| --- | --- |
| Add a meter type | Generator: `npm run createResource -- --name Mana --max MaxMana --regen ManaRegen --visibility ClientVisible`. Create the Properties first with `npm run createProperty -- --name MaxMana --default 100` |
| Charge for an Action | `costs = { Mana = 10 }` on the Action definition |
| Gate an Action without charging | `resourceRequirements = { Mana = { min = 30 } }`; also `max`, `minPercent`, `maxPercent` (0–1) |
| A cooldown | Resource with `max = { value = 1 }` and `regen = { rate = { value = 1 / seconds } }`; the Action requires `{ minPercent = 1 }` and costs `1` |
| Charges | Resource with `max = { value = n }`; the Action costs `1` |
| World or game event gives value | `resources:Restore(id, amount)`, which stops at the maximum |
| World or game event removes value | `resources:Drain(id, amount)`, which stops at the minimum |
| All-or-nothing payment outside an Action | `resources:Spend(id, amount)` |
| Set exactly | `resources:SetCurrent(id, value)`, which clamps |
| Give one Actor a Resource later | `resources:AddResource(id, initialValue?)` |
| Per-Actor bounds | `KRF.ActorRuntime.RegisterActor(model, { properties = { MaxMana = 150 } })` |
| Refund | Explicit `Restore` in game code; KRF never refunds costs |
| Show on a client | `actorView:GetResources():GetResource(id)` each frame |
| React on a client | `actorView:GetResources().OnResourceChanged`, which fires for server changes only |
| React on the server | `resources.OnResourceChanged`, which fires up to 10×/s per regenerating Resource |

## Definition fields

`id` (string, required) · `max` (source, required) · `min` (source, default `{ value = 0 }`) · `initialValue` (number, default the resolved max) · `visibility` (`"ClientVisible"` | `"ServerOnly"`, required) · `autoAssign` (boolean, default `false`) · `regen` (`{ rate = source }`, per second).

A source is exactly one of `{ value = number }` or `{ propertyName = "RegisteredProperty" }`. A Resource source never takes `defaultBaseValue`; that belongs on the Property definition. Unknown fields are ignored silently, so check spelling.

## Server API

Get the controller with `actor:GetController("ResourceController") :: KRF.ResourceController?`. Get the Actor from a Model with `KRF.ActorRegistry.GetActorByModel(model)`.

| Method | Returns | Failure reasons |
| --- | --- | --- |
| `AddResource(id, initialValue?)` | `(boolean, string?)` | `UnknownResourceId:<id>`, `ResourceAlreadyAssigned`, `InvalidResourceOverrideValue`, `ResourceResolvedMaxLessThanResolvedMin`, `ResourcePropertyNonFinite:<p>`, `ResourceControllerDestroyed` |
| `Spend(id, amount)` / `CanSpend` | `(boolean, string?)` | `ResourceNotAssigned`, `InvalidResourceAmount`, `InsufficientResourceValue` |
| `Restore(id, amount)` / `Drain` | `(boolean, string?)` | `ResourceNotAssigned`, `InvalidResourceAmount` |
| `SetCurrent(id, value)` | `(boolean, string?)` | `ResourceNotAssigned`, `InvalidResourceValue` |
| `HasResource(id)` | `boolean` | |
| `GetCurrent` / `GetMin` / `GetMax(id)` | `number?` | `nil` when not assigned |

Amounts must be finite and non-negative. `Spend` measures the value above `min`, not above 0. A call that leaves the value unchanged returns `true` and fires no event.

Server events: `OnResourceAdded: Event<(Actor, string)>` and `OnResourceChanged: Event<(KRF.ResourceChange)>`. A `ResourceChange` has `actor`, `resourceId`, and old/new pairs `currentOldValue`/`currentNewValue`, `minOldValue`/`minNewValue` and `maxOldValue`/`maxNewValue`.

## Client API

`actorView:GetResources()` returns a `KRF.ResourcesView`, which always exists:

- `GetResource(id)` returns a frozen `KRF.ResourceSnapshot?` with `resourceId`, `current` (the estimate), `min`, `max` and `regenRate?`.
- `GetCurrent`, `GetMin`, `GetMax`, `GetRegenRate(id)` return `number?`. `HasResource(id)` is `false` for `ServerOnly` Resources.
- `GetAssignedResources()` returns the snapshots sorted by id.
- `OnResourceChanged: Event<(KRF.ResourceViewChange)>` carries `resourceId`, `previous?`, `current?` and `source` (`"Commit"` | `"Baseline"`). Ignore `"Baseline"` for gameplay reactions; it means a full resync.

## Example: a pickup that restores mana

Game-driven value changes call the controller directly. Abilities use `costs` instead.

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local MANA_PER_PICKUP: number = 30

local ManaPickup = {}

function ManaPickup.Attach(part: BasePart): ()
	part.Touched:Connect(function(hit: BasePart)
		local character: Model? = hit:FindFirstAncestorOfClass("Model")
		local actor: KRF.Actor? = if character ~= nil then KRF.ActorRegistry.GetActorByModel(character) else nil
		local resources: KRF.ResourceController? = if actor ~= nil
			then actor:GetController("ResourceController") :: KRF.ResourceController?
			else nil

		if resources == nil or not resources:HasResource("Mana") then
			return
		end

		local restored: boolean, reason: string? = resources:Restore("Mana", MANA_PER_PICKUP)

		if restored then
			part:Destroy()
		else
			warn(`Mana pickup failed: {reason}`)
		end
	end)
end

return ManaPickup
```

For a HUD bar, read `actorView:GetResources():GetResource("Mana")` in `RunService.RenderStepped`. Compute `(current - min) / (max - min)` when `max > min`. In a `create-krf` project, get the local character's view with the starter's `LocalCharacter.Get()`.

## Wrong patterns

| Wrong | Right |
| --- | --- |
| `resources:Spend("Mana", 10)` then `RequestAction(...)` | `costs = { Mana = 10 }` on the Action |
| A custom `ManaController`, a NumberValue or a RemoteEvent for a meter | A Resource, read through `ResourcesView` |
| `PropertyController:SetBaseProperty("Mana", ...)` for current mana | `ResourceController:SetCurrent("Mana", ...)` |
| `{ propertyName = "MaxMana", defaultBaseValue = 100 }` | A `MaxMana` Property with `defaultBaseValue = 100`, and the source `{ propertyName = "MaxMana" }` |
| Redrawing a HUD only in the client's `OnResourceChanged` | Read every frame; the event skips regeneration |
| Calling `Step` to make regen happen | Set `regen`; KRF steps automatically |
| Ignoring the `(boolean, string?)` result | Branch on it and surface the reason |
| `ClientVisible` for a private value | `ServerOnly` |

## Verify

- **Installed contracts:** `Packages/_Index/kevmp_krf@<version>/krf/src/server/Resource/types.luau` for the server, and `.../src/client/Actor/types.luau` (`ResourcesView`) for the client. The version is in `wally.toml`.
- **A definition loads:** `npm run test:studio` fails with `system = "Resource"` and the reason if any definition is invalid, such as `UnknownPropertyId:MaxMana`.
- **Types and style:** `npm run check`.
- **Behavior you cannot run:** say so. Don't claim a meter refills or replicates without having played it.

## Related

- Action costs and requirements: `../actions/grants-requirements-costs.md`
- Properties that drive bounds and rates: `tags-and-properties.md`
- Getting a client ActorView: `../client/views.md`
