---
slug: /
description: Kevin's Roblox Framework is a reusable, server-authoritative combat and RPG framework for anime-inspired Roblox games.
sidebar_position: 1
sidebar_label: KRF Overview
displayed_sidebar: docsSidebar
---

# Kevin's Roblox Framework

**A server-authoritative gameplay framework for anime-inspired Roblox games.**

KRF connects the full gameplay chain—from input and actions to combat results, replicated state, and presentation—under one Actor-centered runtime. You define the game; KRF provides the architecture that keeps its systems coherent.

[Start with the runtime](./Actor/actor-runtime) · [Browse the API](/api/Actor/actor-runtime) · [View on GitHub](https://github.com/KevMP/KRF)

## One gameplay model

Players, NPCs, bosses, summons, and training dummies are all Actors. Player input and AI intent enter the same action system, follow the same gameplay rules, and produce server-authoritative outcomes.

**Input or AI intent → Action → Validation → Gameplay outcome → Replication and presentation**

Tags, properties, resources, movement, combat, and presentation participate in that shared pipeline instead of inventing separate state, lifecycle, and networking rules.

## From runtime spine to complete game

The runtime spine covers Actors, statuses, numeric properties, resources, actions, input, replication, and debugging. It gives gameplay state a clear owner and gives every core operation a consistent entrypoint.

On top of that spine, KRF brings together combat resolution, health and knockdown, movement, inventory and equipment, abilities, quests, dialogue, world interactions, AI, animation, and effects. These systems are designed to work together without forcing game-specific content into the framework.

## Built to become your game

KRF defines runtime rules, not fiction. It does not prescribe a universe, power source, class system, progression model, combat style, or visual identity.

Your game owns its world, characters, abilities, items, quests, balance, assets, interface, and presentation. Persistence, matchmaking, monetization, analytics, and final UI theming also remain outside KRF.

## Start with the runtime

- [Actor Runtime](./Actor/actor-runtime)
- [Tags](./Tags/tag-runtime) and [properties](./Property/property-runtime)
- [Resources](./Resource/resource-runtime)
- [API Reference](/api/Actor/actor-runtime)
