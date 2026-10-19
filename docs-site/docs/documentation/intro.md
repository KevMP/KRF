---
slug: /
description: Kevin's Roblox Framework provides Actor lifecycle, gameplay state, Actions, and replication for Roblox games.
sidebar_position: 1
sidebar_label: KRF Overview
displayed_sidebar: docsSidebar
---

# Kevin's Roblox Framework

KRF is a server-authoritative gameplay framework for anime-inspired Roblox games. It owns Actor lifecycle, Tags, numeric properties, Resources, Actions, and schema-defined replication. Your game supplies definitions, gameplay behavior, and presentation.

## Find the owning system

| I want to… | Use |
| --- | --- |
| Register a player character, NPC, or boss | [Actor Runtime](./Actor/actor-runtime) |
| Define an ability's requirements, costs, and lifetime | [Actions](./Action/actions-overview) |
| Apply statuses, buffs, or debuffs | [Tags](./Tags/tag-runtime) |
| Read numeric values after modifiers | [Properties](./Property/property-runtime) |
| Define Stamina, Mana, or another meter | [Resources](./Resource/resource-registry) |
| Read visible replicated state for UI or effects | [Client ActorViews](./Networking/actor-views) |
| Replicate additional game-owned state | [Replication domains](./Networking/replication-domains) |
| Integrate KRF into a place manually | [Initializing KRF](./initializing-krf) |
| Look up a method or event | [API reference](/api/Actor/actor-runtime) |

Players and NPCs use the same Actor and controller model. Registries hold static definitions; Actor-owned controllers manage live state. Actions declare payment through Resources, Tags modify properties, and client views expose immutable replicated state.

## Current scope

The available runtime does not include complete input, combat, movement, inventory, quest, AI, or presentation systems. ActorViews expose registered replication domains, active ClientVisible Tags through [TagsView](./Tags/tag-views), and assigned ClientVisible Resources through [ResourcesView](./Resource/resource-views). A built-in Actions domain is not available yet; Action `ClientVisible` metadata alone does not publish state.

KRF does not prescribe your game's world, abilities, progression, or visual identity. Persistence, matchmaking, monetization, analytics, and final UI theming remain outside its scope.
