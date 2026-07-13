---
sidebar_position: 1
sidebar_label: Runtime Foundations
---

# Runtime Foundations

By the end of this lesson, you should be able to choose the KRF system that owns a piece of gameplay state.

## Prerequisite

You should be comfortable with Roblox server scripts, ModuleScripts, Luau tables, and object cleanup.

## The ownership model

KRF organizes gameplay around Actors. Registries define shared static data; controllers hold live state for one Actor.

| Gameplay question | Owner |
| --- | --- |
| Is this model participating in gameplay? | `ActorRuntime` |
| What does `Status.Stunned` mean? | `TagRegistry` |
| Is this Actor stunned right now? | `TagController` |
| What is this Actor's final movement speed? | `PropertyController` |
| How much stamina does this Actor have now? | `ResourceController` |
| What are stamina's authored bounds and regen source? | `ResourceRegistry` |

The distinction to remember is **definition versus instance**:

- A registry entry is shared and static for the server lifetime.
- A controller record belongs to one Actor and changes during gameplay.

## Walk through a sprint

1. `TagRegistry` defines `Buff.Sprint` and its `WalkSpeed` modifier.
2. `ResourceRegistry` defines `Resource.Stamina` and its bounds.
3. `ActorRuntime` registers a character and attaches its controllers.
4. `ResourceController:Spend(...)` pays the sprint cost atomically.
5. `TagController:AddTag(...)` activates the sprint state.
6. `PropertyController` resolves the Actor's final `WalkSpeed` from the active tag.

Each system owns one part of the outcome. No system needs to duplicate another system's state.

## Exercise

Choose an owner for each value before opening the answers:

1. A fire effect's shared tick interval.
2. One NPC's remaining fire duration.
3. A player's property-backed base maximum stamina after leveling up.
4. That player's current stamina.

<details>
<summary>Check your answers</summary>

1. `TagRegistry`
2. `TagController`
3. `PropertyController`
4. `ResourceController`

</details>

## Checkpoint

You are ready to continue if you can explain why current stamina is not a property: properties may supply the resolved bounds and regeneration rate, but `ResourceController` owns the current meter and its spending rules.

## Next

Read [Actor Runtime](/Actor/actor-runtime) to learn how KRF creates the controller boundary for each gameplay participant.
