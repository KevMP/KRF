---
title: Hints
sidebar_label: Guide
---

# Hints

If the next aim sample can replace the last, or a cosmetic pulse can be missed, send it as a Hint. Hints carry disposable presentation data from client to server or server to client.

Use a [Command](../commands/guide) when the sender needs an accepted or rejected result. Use [replication](../replication/guide) when a later client must recover the current value. A Hint has neither acknowledgement nor replay.

## Pick Pulse or Latest

`Pulse` queues each admitted sample as a separate occurrence. `Latest` replaces an unsent sample with the newest one for that definition and target, independently for each recipient. On receipt, Latest suppresses duplicate and older samples for that live target.

Both modes can lose messages, and neither promises delivery order. Keep Resource spending and Action admission in their server-owned systems; Hint receivers should only update disposable presentation.

## Define a server-to-client sample

This small catalog exposes a presentation intensity for an Actor:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = require(ReplicatedStorage.Packages.KRF)

local hints: { KRF.HintDefinition } = {
	{
		id = "Presentation.Intensity",
		direction = "ServerToClient",
		target = "Actor",
		mode = "Latest",
		payload = KRF.Schema.Struct({ value = KRF.Schema.F32 }),
	},
}
```

Pass it to `Server.Init({ hints = hints })`. Server code chooses each recipient explicitly:

```lua
local ok, reason = KRF.ServerHintRuntime.SendTo(player, "Presentation.Intensity", actor, {
	value = 0.75,
})
```

That recipient must be ready and aware of the Actor. A true return means local admission only. If the target disappears before receipt, the sample may be discarded. There is no automatic broadcast or relay to other players.

The client subscribes to `ClientHintRuntime.OnHintReceived`:

```lua
local connection = KRF.ClientHintRuntime.OnHintReceived:Connect(function(receipt)
	if receipt.hintId == "Presentation.Intensity" then
		print(receipt.actorView, receipt.payload.value)
	end
end)
```

Keep the connection with that presentation consumer and disconnect it during cleanup. Receipts describe delivered samples, so initialize any persistent display from replicated state and decide how disposable feedback should settle when samples stop arriving.

## Authorize client-originated Hints

A `ClientToServer` definition requires both `authorize(ctx, payload)` and `receive(ctx, payload)`. Return exactly true from authorization to allow the receiver to run. Other results deny the sample; any second return value is ignored. Errors and yields also drop the sample, and KRF closes a callback that suspends at its first yield.

`HintAuthorization.OwnerActor` permits only the requester's exact current Character Actor; `AnyReadyClient` permits any ready requester. A custom policy can check the game's permission rules. Its context contains the requesting Player, resolved Actor when targeted, and Hint ID. Use the context and helpers during the callback that received them.

The client sends through `ClientHintRuntime.Send(hintId, actorView, payload)`. There is no request ID or outcome event. Denial, a receive fault or packet loss produces no acknowledgement to the sender. Server-to-client forwarding, when desired, is an explicit server decision with its own recipient and admission checks.

## Keep samples small and replaceable

Payloads use ordinary [Schemas](../schemas/guide). The current complete Hint packet ceiling is 900 bytes, including framing; a payload cannot consume that entire size by itself. Startup rejects definitions whose maximum record cannot fit. Rate, queue and aggregate budgets still apply at runtime.

KRF encodes and owns admitted payloads before returning, so mutating a source table later does not rewrite a queued sample. Admitted work can still be discarded if its target mapping changes or its connection ends. A missing or unavailable client Actor target drops without waiting for a baseline or initiating state recovery.

See the [Hints API](./api) for definition fields, runtime calls and failure behavior.
