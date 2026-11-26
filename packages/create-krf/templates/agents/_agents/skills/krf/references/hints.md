# Hints

A Hint is a small, disposable message for presentation, such as an impact effect or where another player is aiming. It can be lost, it has no answer, and nothing replays it. Use one only when missing it is harmless.

## Check whether it should be a Hint

| The data | Use |
| --- | --- |
| Can be dropped, and only changes how things look or sound | A Hint |
| Changes gameplay, such as damage, spending or starting something | An [Action](actions.md) or a [Command](commands.md) |
| Must still be right for a player who joins or respawns later | A `ClientVisible` [Tag](tags.md) or [Resource](resources.md), or a [replication domain](replication.md) |
| Is a one-time effect tied to an Actor's state change, such as a level-up | An event on that state's domain, or the Tag or Resource event clients already get |

Many effects need no Hint at all. A client can already play a burning effect from the Burning Tag, or a cast animation from the running Action in its [ActorView](client-views.md).

## Pick a direction and a mode

| Option | Values |
| --- | --- |
| `--direction` | `ServerToClient` (default) or `ClientToServer` |
| `--target` | `Actor` (default) when the message is about a character, `None` otherwise |
| `--mode` | `Pulse` (default) keeps every message. `Latest` keeps only the newest unsent one, for values where only the current sample matters |

Neither mode guarantees delivery or order. Payloads use [schema types](replication.md#pick-schema-types), and a whole Hint must fit in 900 bytes.

For every flag and how to read the result, see [generators.md](generators.md#createhint).

## Send an effect to clients

```bash
npm run --silent createHint -- --name ImpactEffect --target None --payload-field "Position:Array(F32,3)" --yes --json
```

The server picks every recipient itself. There's no broadcast, so loop over the players:

```lua
local function showImpact(position: Vector3): ()
	for _, player: Player in Players:GetPlayers() do
		KRF.ServerHintRuntime.SendTo(player, "ImpactEffect", nil, { Position = { position.X, position.Y, position.Z } })
	end
end
```

`SendTo` returns `false, reason` for a player who isn't ready yet. That's expected for a Hint; skip them.

On the client, listen for it:

```lua
KRF.ClientHintRuntime.OnHintReceived:Connect(function(receipt: KRF.HintReceived): ()
	if receipt.hintId ~= "ImpactEffect" then
		return
	end

	local position: { number } = receipt.payload.Position
	playImpact(Vector3.new(position[1], position[2], position[3]))
end)
```

For an `Actor` target, pass the Actor to `SendTo` and read `receipt.actorView` on the client. A Hint for an Actor the client can't see yet is dropped.

## Send samples from the client

A client-to-server Hint needs `authorize` and `receive`. This one lets a player share where they're aiming so the server can show it to everyone else:

```bash
npm run --silent createHint -- --name AimSample --direction ClientToServer --mode Latest --payload-field "Direction:Array(F32,3)" --authorize OwnerActor --yes --json
npm run --silent createHint -- --name AimPresentation --mode Latest --payload-field "Direction:Array(F32,3)" --yes --json
```

There's no relay, so `receive` forwards the sample to the other players itself:

```lua
receive = function(ctx: KRF.HintContext, payload: { Direction: { number } }): ()
	for _, player: Player in Players:GetPlayers() do
		if player ~= ctx.player then
			KRF.ServerHintRuntime.SendTo(player, "AimPresentation", ctx.actor, payload)
		end
	end
end,
```

- `authorize` allows the sample only when its first return is exactly `true`. `KRF.HintAuthorization.OwnerActor` allows a player to send for their own character.
- `receive` must not yield, and must never drive gameplay. A client can send any value. Never use a Hint's aim for hit detection; the [Action](action-input.md#check-the-claim-on-the-server) carries and checks its own aim.
- Errors, yields and denials drop the sample silently. The client never finds out.

On the client, send at a steady rate instead of every frame. Each client gets about 256 Hint sends a second across every Hint, and `Send` returns `false, "HintRateLimited"` past that:

```lua
local SEND_INTERVAL: number = 0.1
local elapsed: number = 0

RunService.Heartbeat:Connect(function(deltaTime: number): ()
	elapsed += deltaTime

	local view: KRF.ActorView? = LocalCharacter.Get()

	if elapsed < SEND_INTERVAL or view == nil then
		return
	end

	elapsed = 0

	local look: Vector3 = workspace.CurrentCamera.CFrame.LookVector
	KRF.ClientHintRuntime.Send("AimSample", view, { Direction = { look.X, look.Y, look.Z } })
end)
```

## Settle when samples stop

Hints stop without warning: a sender leaves, a packet is lost, a character respawns. Anything a Hint drives on screen should fade or reset on its own when no new sample arrives for a while, rather than freezing on the last one. Draw anything lasting from state.

## Exact APIs

- [Hints guide](docs/hints/guide.md) and [Hints API](docs/hints/api.md): definition fields, `SendTo`, `Send`, `OnHintReceived` and send failure reasons.
- [Schemas API](docs/schemas/api.md): payload field types.

## Related references

- [commands.md](commands.md) for requests that need an answer.
- [replication.md](replication.md) for state clients must recover.
- [client-views.md](client-views.md) for effects driven by Tags, Resources and running Actions.
