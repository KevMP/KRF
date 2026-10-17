---
slug: /
description: Kevin's Roblox Framework provides Actor lifecycle, gameplay state, Actions, and replication for Roblox games.
sidebar_position: 1
sidebar_label: KRF Overview
displayed_sidebar: docsSidebar
---

# Kevin's Roblox Framework

**A server-authoritative gameplay framework for anime-inspired Roblox games.**

KRF owns Actor lifecycle, controller attachment, Tags, numeric properties, Resources, Actions, and schema-defined replication. Client ActorViews expose the authoritative state visible to each player. Your game supplies gameplay behavior and presentation around these runtime contracts.

[Initialize KRF](./initializing-krf) · [Explore Actor Runtime](./Actor/actor-runtime) · [Browse the API](/api/Server/) · [View on GitHub](https://github.com/KevMP/KRF)

## One gameplay model

Players, NPCs, bosses, summons, and training dummies use the same Actor lifecycle and controller model. Server code uses the Action runtime to validate requests, spend Resources, claim locks, and manage active behavior.

**Actor → Controllers → Authoritative state → Replication domains → Client ActorViews**

Tags contribute modifiers, properties resolve numeric values, and Resources own current meters. Replication domains project approved state and semantic events to their intended audience.

## Build on the runtime

Registries validate static definitions at startup. Actor-owned controllers manage live gameplay state; client views provide immutable snapshots and read-only events for UI and effects.

The available runtime does not include a complete input, combat, movement, inventory, quest, AI, or presentation system. Implement game behavior through controllers and Actions, and consume replicated state through [ActorViews](./Networking/actor-views).

## Built to become your game

KRF defines runtime rules, not fiction. It does not prescribe a universe, power source, class system, progression model, combat style, or visual identity.

Your game owns its world, characters, abilities, items, quests, balance, assets, interface, and presentation. Persistence, matchmaking, monetization, analytics, and final UI theming also remain outside KRF.

## Start with the runtime

- [Initializing KRF](./initializing-krf)
- [Actor Runtime](./Actor/actor-runtime)
- [Actions](./Action/actions-overview)
- [Tags](./Tags/tag-runtime) and [properties](./Property/property-runtime)
- [Resources](./Resource/resource-runtime)
- [API Reference](/api/Actor/actor-runtime)
