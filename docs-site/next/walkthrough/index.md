---
title: Build a cultivation game
sidebar_label: Introduction
sidebar_position: 0
slug: /
description: Learn KRF by building a small multiplayer cultivation game, one playable step at a time.
---

# Build a cultivation game

This walkthrough teaches KRF by building one small multiplayer game. In Ascension, players are cultivators. They meditate to gather Qi, spend a full bar of it to break through to higher realms, and join a sect that teaches them a technique. Every chapter ends with the game running and doing something new.

You don't need to know KRF. You should already be comfortable with Luau, Roblox Studio and the client/server split, because the walkthrough doesn't explain those.

## What you'll build

| Chapter | The game gains | KRF you'll use |
| --- | --- | --- |
| [0. Create the project](./create-the-project) | The `create-krf` starter, running in Studio | Project layout, startup, Actors |
| [1. Gather Qi](./gather-qi) | A Qi meter that fills over time | Resources, Properties |
| [2. Meditate](./meditate) | Hold F to gather Qi faster | Actions, Tags, input routes and policies |
| [3. Break through](./break-through) | Hold R with a full bar to reach the next realm | Action updates, costs, locks, game-owned Controllers |
| [4. Show realms to everyone](./show-realms) | Everyone sees realms and breakthroughs | Replication domains, ActorViews |
| [5. Join a sect](./join-a-sect) | Pick a sect and learn its technique | Commands, grants, stacking and ticking Tags, toggles |
| [6. Test the game](./test-the-game) | Automated checks for the game | Jest specs, Studio smoke tests |

The game builds on the project `create-krf` generates and changes it as it grows: the starter's Energy meter becomes Qi, and its Focus ability becomes meditation. New definitions come from the project's generators, which write each module and register it for you. You write the gameplay.

Each chapter shows complete files, or the exact lines to change when only part of a file changes. Run each chapter's checkpoint before moving on; later chapters assume the earlier code works.
