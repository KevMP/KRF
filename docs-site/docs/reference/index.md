---
title: Introduction to KRF
sidebar_label: Overview
slug: /
---

# Introduction to KRF

Kevin's Roblox Framework (KRF) is a Luau framework for building server-authoritative gameplay in Roblox. It gives player characters and NPCs the same foundation for stats, status effects, resources and abilities, with client views of the state they're allowed to see.

An ability rarely works alone. A dash might spend Stamina, refuse to start while the character is Stunned, interrupt another movement ability and tell clients when it starts. As you add abilities, each of those rules needs to keep working across interruptions, respawns and overlapping effects. KRF coordinates those relationships so you can write the behavior of the dash without rebuilding its surrounding lifecycle.

## Give characters a shared foundation

Register a character's Model as an [Actor](./actors/guide). The Actor gives that character an identity and owns its gameplay objects for that lifetime. Players and NPCs use the same model: both can gain statuses, spend resources and run abilities.

[Controllers](./controllers/guide) hold state and behavior belonging to one Actor. KRF supplies Controllers for its gameplay systems; you can add your own for things such as a character's cultivation realm or team. When the Actor is unregistered, its Controllers are destroyed with it. A respawn starts a new Actor lifetime.

Definitions describe the rules shared by Actors. Controllers hold the changing state of each individual Actor, so characters using the same Stamina definition can still have different limits and current values.

## Let stats and effects work together

[Properties](./properties/guide) separate a character's base stats from the values gameplay reads after modifiers. [Tags](./tags/guide) represent statuses such as Stunned, Blocking or Winded, with optional durations, stacks and Property modifiers.

A Winded Tag can halve a StaminaRegen Property while leaving its base value alone. Removing Winded removes its contribution; game code doesn't need to remember and restore an old stat that another effect may have changed.

[Resources](./resources/guide) hold values characters spend and regain. Their bounds and regeneration can follow Properties, so that same Winded effect can change how quickly Stamina recovers. ResourceController handles exact spending, clamped drains and restoration. An Action can declare its costs so payment happens only when the ability is accepted.

## Give abilities a lifecycle

An [Action](./actions/guide) brings an ability's admission rules and running behavior together. Its definition can require a grant, check Tags and Resources, declare costs and claim locks that exclude conflicting abilities. Callbacks supply the game-specific behavior.

Each activation has its own state and identity. It can complete, be interrupted or respond to a stop request. When it ends, KRF releases its locks and removes Tag applications it still owns. Effects meant to outlive it keep their own lifetimes.

This gives you a place to answer questions such as whether a dash can interrupt a charge, whether releasing a key should end meditation, and which statuses should disappear when an ability is cancelled.

## Connect player intent to authoritative state

[InputRuntime](./input/guide) gives keys, buttons and axes gameplay names and recognizes gestures or sequences. [Action routes](./actions/routes) map those inputs to abilities for the controlled Actor. [ClientControls](./controls/guide) changes inputs, routes, contexts and Actor selection together when they depend on one another.

The client sends an [Action request](./actions/requests); the server checks authority and the Action's gameplay rules before accepting it. Other client-to-server operations can use [Commands](./commands/guide), which have explicit authorization and an accepted, rejected or uncertain outcome.

Clients read published state through [ActorViews](./actors/client-views). Visible Tags, Resources and active Actions already have typed views. For your own Controller state, a [replication domain](./replication/guide) defines the snapshot and events clients receive. [Schemas](./schemas/guide) give networked values explicit shapes and size bounds.

Current state lets a client rebuild its display after joining or recovering. Events describe occurrences such as an ability starting. For disposable presentation samples that can be missed or replaced, use [Hints](./hints/guide).

Use [Presentation](./presentation/guide) to run client visuals when a delivered Action, Tag, Resource or Hint matches a game definition. Each instance can own its visual objects and clean them up when it finishes or its Actor retires.

## Start building

[Build a cultivation game](/tutorial/) walks through these ideas in a working project: gathering Qi, meditating, advancing through realms and joining a sect.

To integrate KRF into an existing game, start with [Initialization](./getting-started/initialization). Each system's guide explains how to use it and how it interacts with the others; its API page gives signatures, data shapes, events and failure behavior.
