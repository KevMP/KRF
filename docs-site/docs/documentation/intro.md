---
slug: /
sidebar_position: 1
sidebar_label: KRF Overview
displayed_sidebar: docsSidebar
---

# Kevin's Roblox Framework

KRF is a server-authoritative, Actor-centered runtime for Roblox combat and RPG games. It owns shared gameplay lifecycle and state rules; your game owns content, balance, presentation, and progression design.

## Runtime map

| System | Owns | Does not own |
| --- | --- | --- |
| Actor Runtime | Model binding, Actor lifecycle, controller attachment and teardown | Game-specific character rules |
| Tag Runtime | Active statuses, stacks, durations, ticks | Static tag definitions or final numeric values |
| Property Runtime | Base and resolved numeric Actor properties | Current resource meters |
| Resource Runtime | Actor-scoped meters, bounds, costs, regeneration | The numeric properties used as live sources |
| Registries | Static tag, resource, and controller definitions | Per-Actor state |

## Choose the owning system

| You need to represent… | Use… |
| --- | --- |
| A gameplay participant bound to a `Model` | Actor Runtime |
| A stun, buff, debuff, stack, or timed status | Tag Runtime |
| A numeric stat modified by active tags | Property Runtime |
| A spendable or regenerating meter | Resource Runtime |
| Startup-authored definitions shared by every Actor | The matching registry |

## Server flow

1. Load static tag and resource catalogs.
2. Register controller definitions and dependencies.
3. Register a model through `ActorRuntime`.
4. Read and mutate gameplay state through the Actor's controllers.
5. Unregister the Actor when its gameplay lifecycle ends.

Registries are loaded once. Actors and their controller state are created and destroyed throughout the server lifetime.

## Scope

KRF is not a game template, ECS, datastore, matchmaking service, UI theme, monetization layer, or analytics system. It supplies the gameplay runtime spine those game-specific systems can build on.

## Start here

- [Actor Runtime](./Actor/actor-runtime): lifecycle and controller composition.
- [Tag Registry](./Tags/tag-registry) and [Tag Runtime](./Tags/tag-runtime): authored meaning and live status state.
- [Property Runtime](./Property/property-runtime): base and tag-resolved numbers.
- [Resource Registry](./Resource/resource-registry) and [Resource Runtime](./Resource/resource-runtime): meter definitions and live values.
- [API Reference](/api/Actor/actor-runtime): exact signatures, failures, payloads, and ordering.
