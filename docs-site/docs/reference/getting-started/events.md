---
title: Events and connections
---

# Events and connections

KRF's public events let you subscribe without exposing the Signal that owns notification. Keep each subscription with the consumer that needs it, then disconnect when that consumer is removed.

```lua
local connection: KRF.Connection = resources.OnResourceChanged:Connect(function(change: KRF.ResourceChange)
	if change.resourceId == "Stamina" then
		print(change.currentNewValue)
	end
end)

-- In this consumer's cleanup:
connection:Disconnect()
```

The resource controller owns the event, while your consumer owns this connection. Disconnecting one connection does not disconnect other subscribers.

## API

| Signature | Contract |
| --- | --- |
| `event:Connect(callback: (T...) -> ()) -> KRF.Connection` | Subscribes a callback with the event's declared arguments |
| `event:Once(callback: (T...) -> ()) -> KRF.Connection` | Subscribes for one delivery, then disconnects |
| `event:Wait() -> T...` | Yields the calling coroutine until an event delivery |
| `connection:Disconnect() -> ()` | Stops future delivery to this connection |

`KRF.Event<T...>` describes the read-only event surface. It has no `Fire`, `Destroy` or `DisconnectAll` method. Calling Connect, Once or Wait on an Event whose owner has destroyed it throws `Event: destroyed`.

Disconnect is idempotent and prevents future delivery; it does not cancel a callback already running. General event listeners can yield, and an error in one listener does not stop other listeners. Their completion order is not a synchronization guarantee.

Wait has no cancellation return. Destroying its Event does not resume a waiting coroutine. Use a retained connection when a consumer needs explicit lifecycle cleanup.

## Read notifications as transitions

Each system defines its payload and ordering. Gameplay change events normally describe a committed transition. A callback can cause another change, so an older event payload and a fresh query can legitimately describe different states.

Lifecycle events can announce work that is about to happen. For example, `OnActorViewRemoving` runs while the view is still registered, before it is destroyed. Baseline and live Actor publications install their affected state before notification, but that guarantee does not change the timing of removal events.

Don't use `Wait` or another yield inside callbacks that a definition requires to be synchronous, including domain snapshots, authorization, input resolvers and Action updates. Those contracts are stricter than the general event subscription interface.

Client baselines represent current state, not a replay of history. Use state-change notifications to refresh a readout and semantic events for occurrences that should happen only once. [ActorViews](../actors/client-views) explains that distinction.

## Own events in game code

A game [Controller](../controllers/guide#give-a-controller-events) can raise its own events with the same Signals KRF uses. The owner keeps the `KRF.Signal`, exposes only an Event made from it, and destroys its Signals together through `KRF.OwnedSignals`.

| Signature | Contract |
| --- | --- |
| `KRF.Signal.new() -> KRF.Signal<T...>` | Creates a Signal the caller owns |
| `KRF.Signal.wrapEvent(signal: KRF.Signal<T...>) -> KRF.Event<T...>` | Returns a read-only Event over the Signal; throws for a value that isn't a Signal or a destroyed Signal |
| `signal:Fire(T...) -> ()` | Delivers to every connection without waiting for listeners to finish |
| `signal:DisconnectAll() -> ()` | Disconnects every connection and keeps the Signal usable |
| `signal:Destroy() -> ()` | Disconnects everything and makes the Signal and its Events unusable |
| `KRF.OwnedSignals.new(signals: { KRF.Signal<...> }) -> KRF.OwnedSignals` | Groups Signals for teardown; later changes to the passed array don't change the group |
| `owned:WithDeferredDestroy(callback: () -> ()) -> ()` | Runs the callback; a Destroy requested during it waits until the outermost callback returns. Throws if the Signals are already destroyed and rethrows the callback's error |
| `owned:Destroy() -> ()` | Destroys every Signal in the group once; repeated calls do nothing |

Fire inside `WithDeferredDestroy` when a listener could end the owner's lifetime, for example by unregistering the Actor whose Controller is firing. The remaining listeners still receive the event, and the Signals are destroyed afterwards.
