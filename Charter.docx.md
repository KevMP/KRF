**RPG Framework Charter**

| Project name | Kevin’s Framework |
| :---- | :---- |
| Owner | Kevin |
| Version | 0.0.0 |
| Last updated | 1/31/2026 |
| Repository | \[TBD\] |
| License | \[TBD\] |

# **1\. Mission and elevator pitch**

**Mission:** To provide a reusable, high quality combat and RPG framework for anime inspired Roblox games that solves the hard runtime and architectural problems, so developers can focus on lore, visuals, and game feel and ship complete games in 1 \- 2 months of scripting when assets are ready.

**Elevator pitch:** Most anime and anime inspired Roblox games are built on the same core ideas: ability based combat, RPG stats, and familiar gameplay loops. Yet they’re often rushed together, enjoy short seasonal success, and rarely have a solid underlying architecture. This framework aims to change that by offering a complete, battle tested foundation that abstracts the difficult runtime, networking, and event driven decisions for you. Instead of reinventing combat systems every project, developers plug into a consistent framework, focus on their specific lore and presentation, tune the feel of the game, and with assets, animations, and maps in place can realistically reach a full game in 1 \- 2 months of scripting.

# **2\. Target games and primary use cases**

| Example game | Combat/RPG features it relies on | Framework Requirement |
| :---- | :---- | :---- |
| Naruto RPG | Jutsu, Abilities, Passive and Active effects, stats, quests | Needs a highly extensible ability system that can represent many jutsu types (melee, projectiles, buffs, clones, etc.), support both passive and active effects, and apply status effects in a consistent way during combat. |
| Combat Arena Game | Combat, Weapons, Quests | Requires a fast, server authoritative combat core with reliable hit detection, weapon \+ ability execution, stun/knockback/iframes handling, and clear rules for priority, cancels, and clash resolution between abilities. |
| Magic Game | Magic Abilities, Stats, Quests | Needs an element-agnostic spell system that supports projectiles, AoE zones, channeled/charged casts, and combo interactions, all driven by a common ability lifecycle and effect application pipeline. |
| Wuxia Cultivation Game | Quests, Loot, Stats, Combat, Abilities, Flying | Requires advanced movement and combat support: dashes, air control, flying / gliding hooks, layered buffs/debuffs, and long combo chains, all integrated into the same ability \+ state system used by simpler games. |

# **3\. What this framework is NOT**

Non-goal: Datastore and Data Persistence solution

Non-goal: Matchmaking, lobbies, or round systems

Non-goal: Final UI theming and layout 

Non-goal: Monetization or analytics

# **4\. Scope of included systems**

This section defines which systems the framework ships with, what components are optional, and what each game must still implement.

## **System: Actor / Character Runtime**

**Framework Provides:**

* Standard Actor abstraction for anything that participates in combat/gameplay (players, npcs, training dummies, bosses), which bundles together with the entity’s TagController, ActionController, etc.  
* A registration/ binding API to attach an actor to a Character or rig model creating and wiring its controllers on the server and with proper client replication.  
* A consistent lifecycle for actors in M0: spawn/register → live → unregister/teardown, ensuring tags/actions and any internal timers owned by controllers are torn down correctly when the Model is removed or the actor is explicitly unregistered.  
* A simple lookup layer so other systems can reliably go from a Roblox instance or id to the corresponding Actor without everyone keeping their own tables.  
* Clear server vs client semantics for actors:  
  * Server owns the authoritive controllers  
  * Client interacts and reactions through replicated snapshots / events for UI, VFX and prediction.

**Actor Runtime Clarification (M0 Contract)**

* Respawn policy: a respawned character is treated as a new Actor (no pooling).  
* No soft-disable in M0: there is no dedicated “Disable/Death” lifecycle API in M0. Games may represent death/downed states via tags/actions and/or by unregistering and respawning.  
* Lifecycle ownership: ActorRuntime owns actor creation/teardown; cleanup is valid via explicit unregister or automatic cleanup when the bound Model becomes nil / is deleted.

**Game must do:** 

* Decide which game entities are treated as Actors  
* Call the framework’s registration API whenever an actor is spawned/respawned, and hook this into the game’s existing spawn, respawn, and cleanup flows

## **System: Tag & Status Runtime**

**Framework Provides:**

* A registered tag catalog: tags must be defined up front with an ID and optional metadata (default duration, tick interval, property modifiers, stacking/duplicate behavior).  
* A server-authoritative tag runtime that tracks which tags are active on each actor, supports adding/removing tags, and can apply tags with an optional duration (e.g., add Status.Stunned for 1 second).  
* Built-in support for timed tags: the runtime handles countdown, expiry, and calls optional per-tag tick behavior (e.g., OnFire dealing damage every tick) without game code manually managing timers.  
* A property modifier pipeline driven by tags that computes resolved property values and emits change events:  
  * Out of the box, tags can contribute movement property multipliers (e.g., WalkSpeedMultiplier, JumpHeightMultiplier) and/or resolved values (e.g., effective WalkSpeed), such as Sprint ×1.2, Slow ×0.8 → combined multiplier.  
  * The same mechanism can be extended to other named properties (e.g., AttackSpeed, ManaRegen) that game code reads when making decisions.  
  * Applying resolved movement values to Humanoid is owned by the Movement & Mobility Runtime (M1).  
* Query & event API so other system can react to tags:  
  * Queries like HasTag, GetActiveTags, ect.  
  * Events for tag added/removed/expired and for property value changes, for use by abilities, AI, movement, and UI/VFX.  
* An introspection/snapshot hook that exposes the current active tags (and remaining durations) on an actor so an external persistence layer or debug tooling can inspect or save them if needed

**Tag & Status Runtime Clarification (M0 Contract)** 

* Property ownership in M0: Tags do not own base numeric properties. Tags contribute modifiers and status state, while the Property Runtime owns base values, resolved values, and property change events.

* Built-in property baseline: M0 guarantees built-in numeric property support for \`WalkSpeed\` and \`JumpPower\`. Additional named numeric properties may be supported through the same Property Runtime contract without introducing a full stat/progression system.

* Movement boundary: The Tag & Status Runtime and Property Runtime compute resolved movement-related values, but applying those values to Humanoids is owned by the Movement & Mobility Runtime.

**Game must do:** 

* Define the actual tag catalog for the game (e.g., Status.Stunned, Buff.Sprint, Status.OnFire), including default durations, whether duplicates stack/refresh/are ignored, and any property modifiers they contribute.  
* Implement any tag-specific behavior inside the provided hooks (e.g., OnFire dealing 1 damage per tick).  
* Subscribe relevant systems (movement, combat, abilities, AI, UI/VFX) to tag and property change events to drive actual gameplay and visuals based on the tag state.  
* Tune balance values (durations, multipliers, tick damage, etc.) for each tag to fit the game’s desired feel.

## **System: Resource Runtime**

**Framework Provides:** 

* Server-authoritative Resource Runtime for actor-scoped gameplay meters such as stamina, mana, energy, rage, guard, posture, breath, focus, heat, or similar game-defined resources.  
* Per-actor ResourceController that owns current resource values, validates resource changes, clamps values within configured bounds, and emits change events when resource state changes.  
* Data-driven resource definition model so games can declare which resources exist, how they are initialized, whether they regenerate, and whether they are visible to clients.  
* Integrates with the Property Runtime so resource limits and rates can be driven by resolved properties such as MaxStamina, StaminaRegen, MaxMana, ManaRegen, or other game-defined numeric properties.  
* The framework integrates with the Action System so actions can declare resource costs and have those costs validated and consumed through the Resource Runtime instead of directly mutating resource state.  
* Exposes read only resource snapshots for debug tools, UI, AI, replication, and other systems that need to inspect resource state without reaching into internal controller data.  
* The framework does not automatically treat Health as a Resource Runtime value. Health, damage, knockdown, downed state, death, execution, and revive behavior remain owned by the Combat Resolution & Health / Knockdown system.

**Game must do:** 

* Define which resources exist for its gameplay and which actors receive those resources.  
* Define each resource’s balance rules, including initial values, maximum values, regeneration behavior, cost tuning, drain behavior, and client visibility.  
* Define any supporting properties that resources depend on, such as max-value properties, regeneration properties, or cost-modifier properties.  
* Define what resource depletion or resource thresholds mean at the gameplay level, such as stamina preventing dodges, guard causing a guard break, rage enabling an ultimate, or breath limiting underwater movement.  
* Build any player-facing UI for resource bars, meters, warnings, or related displays using the framework’s resource snapshots, events, or replicated views.  
* Route resource related gameplay through the Resource Runtime instead of directly mutating custom resource tables from actions, tags, AI, UI, or combat scripts.

## **System: Action System / ActionController**

**Framework Provides:** 

* Provides a per-actor ActionController that manages what that specific actor is doing, using a single, input-agnostic API that supports player and AI.  
  * Example: “request Sprint”, “request Attack”  
* A single, validated request API for starting actions (used by networking, input, and AI) that accepts an actionId and optional context/parameters, and returns a clear accept/reject result (with a reason code) so client-side prediction and other systems can reconcile when an action is denied.  
* Exposes a strongly shaped ActionDefinition format (via an ActionRegistry) that all actions must follow (e.g, id, kind, standard lifecycle hooks) so that action data is consistent and type checkable  
* Defines standard action lifecycle (e.g onCanStart, onStart, onUpdate, onEnd, onInterrupt) that every action implements and the controller runtime drives over time.  
* Supports multiple action kinds, (e.g, Instant, Timed, Channelled, Mode) that all share the same lifecycle surface whole the controller helps decide when they naturally finish (fixed duration, input release, toggle off, interrupt etc.).  
* Integrates with the Tag Runtime, reads required / blocked tags before starting an action, applies and removes tags at lifecycle points and reacts to new tags (e.g Status.Stunned) by interrupting or cancelling running actions through OnInterrupt.  
* Maintains per actor action state internally (current running actions, their timers, phases, combo steps, buffers) without exposing these details as tags and provides a read-only introspection snapshot API so other systems can query what an actor is currently doing in a structured way.  
  * Strongly typed internal data structure

**Action Runtime Clarifications (M0 Contract)**

* Action instances: Each accepted request creates an internal ActionInstance with a per-Actor unique sequenceId for reconciliation/introspection.  
* End vs interrupt: Actions end either by natural completion (onEnd) or forced termination (onInterrupt(reason)). All non-natural stops route through onInterrupt.  
* Deterministic concurrency: Actions may declare required locks/channels (e.g., combat, movement, defense, interaction). Only one ActionInstance may hold a lock at a time; on conflict the default behavior is reject with a reason code.  
* Read-only snapshot: ActionController exposes a read-only snapshot of active actions including at least sequenceId, actionId, kind, and held locks. Internal runtime state (timers/phases/combos/buffers) is not represented as tags.

**Action Runtime Clarifications (M0 Contract)**

* No action kinds: ActionDefinition does not classify actions as Instant, Timed, Channelled, Mode, or similar kinds. Action lifetime and behavior are defined by the action implementation itself. Long-lived modes, held actions, channels, and short-lived attacks all use the same ActionInstance model.  
* Explicit action lifetime: Returning from onStart does not implicitly end an ActionInstance. An accepted ActionInstance remains active until it is explicitly ended or interrupted. onUpdate is optional and only used by actions that require controller-driven updates.

**Game must do:**

* Register all game specific actions in the ActionRegistry using the required structure (ids, kinds, tag preconditions/blocks, tag effects, costs, cooldown behavior) and implement their lifecycle hooks (onStart, onUpdate, onEnd, onInterrupt) to perform game-specific behavior (animations, hitboxes, projectiles, movement tweaks, etc.).  
* Route all gameplay-initiated action starts (from player input, AI, or scripted logic) through the ActionController’s request API, rather than directly manipulating tags or internal state, so that validation, cancel rules, and networking remain consistent.  
* End vs. interrupt: End and Interrupt(reason) are distinct explicit termination paths. End routes through onEnd; Interrupt routes through onInterrupt(reason). KRF does not determine what is “natural” or “unnatural”; the action/game determines which termination path is appropriate for a situation.  
* Action-private execution state: ActionController does not interpret game-specific concepts such as startup/recovery phases, combo steps, charge stages, or input buffers. Actions may maintain arbitrary private execution state within their ActionInstance without exposing that state as tags.  
* End vs. interrupt: End and Interrupt(reason) are distinct explicit termination paths. End routes through onEnd; Interrupt routes through onInterrupt(reason). KRF does not determine what is “natural” or “unnatural”; the action/game determines which termination path is appropriate for a situation.  
* Input-agnostic stop handling: Running actions may receive a stop request independently of player input. The action determines what that request means—for example, Sprint may end immediately while a charged attack may treat the request as release/commit behavior before eventually ending.  
* Lock semantics: Locks represent exclusive concurrency claims, not action categories. An action may require multiple locks for its full lifetime, and active actions may also acquire temporary scoped lock claims during execution. Temporary claims are owned by the ActionInstance and are automatically released when that instance terminates.  
* Deterministic preemption: A lock conflict does not inherently require rejection. A running action may explicitly allow particular incoming Action IDs to replace it. An optional runtime refinement hook may further restrict an otherwise allowed replacement, but may not expand the static allowlist. If an incoming action conflicts with multiple active ActionInstances, all conflicts must permit replacement before any existing instance is interrupted.  
* Per-actor action availability: Registration in the ActionRegistry only establishes that an action exists. ActionController also tracks which registered actions a specific Actor is currently authorized to request. ActionDefinitions may opt into automatic granting, while additional grants may be contributed and removed independently by external consumers without ActionController needing to understand the source domain.  
* Grant persistence boundary: Action grants are runtime state. Persistent ownership or unlock state is restored by consumer persistence/bootstrap code through the ActionController grant surface; ActionController does not own data persistence.  
* Cooldowns use Resources: ActionController does not maintain a separate first-class cooldown runtime. Cooldowns, shared cooldowns, charges, global cooldowns, and similar availability meters are modeled through the Resource Runtime and consumed/modified by actions as appropriate.  
* Introspection reflects the revised model: Action snapshots expose active ActionInstances and their framework-owned concurrency state, but do not expose a removed kind field or treat private action execution state as framework-defined phases.

## **System: Input Runtime & Client Action Runtime**

**Framework Provides:**

* A client-side Input Runtime that wraps Roblox input services and exposes high-level input actions with context support, instead of raw key codes:  
  * Supports named input actions (e.g., LightAttack, Dodge, Sprint, Ability1, Mount\_Charge)  
  * Supports input contexts (e.g., Gameplay\_Human, Gameplay\_Monster, Gameplay\_Mount, Dialogue), with simple APIs to enable/disable or push/pop contexts so games can cleanly swap control schemes (transformations, mounts, special modes)  
  * Normalizes hardware input into semantic events like OnInputAction(actionId, phase) where phase is Pressed, Released, Held, DoubleTapped, etc.  
* A per-local-player ClientActionRuntime that sits between the Input Runtime and the server-side ActionController to handle game-side control logic:  
  * Maintains per-actor, per-context control profiles that map input actions to framework ActionDefinition IDs (e.g., in Gameplay\_Human for one actor Dash → Dash\_Action, while for another actor Dash may be unbound until they learn it). These profiles are data-driven and can be updated at runtime (e.g., when a player unlocks Dash, learns a new core move, or changes form/mount).  
  * For core controls (e.g., LightAttack, HeavyAttack, Dash, Block, Sprint), maps input actions directly to Action IDs via these profiles. For slot-style actions (e.g., Ability1–Ability5), it can optionally delegate resolution to an Ability Loadout Runtime (if the game opts into that system) to decide which ActionId is currently bound to each ability slot.  
  * Uses the same input-agnostic request API as AI/server code to ask the ActionController to start actions, via the Networking & Replication Core.  
  * Handles buffering and chaining of inputs (e.g., queuing the next combo hit during recovery windows) so combat feels responsive and consistent.  
  * Handles channelled/mode actions for start/stop semantics (e.g., hold to sprint or breathe fire; release to cancel), routing press/release phases into corresponding action requests.  
  * Provides hooks for client-side prediction and reconciliation: it calls into the PresentationController to start a predicted preview and reconcile when the server accepts or rejects the action (e.g., by sequence ID and reason codes).  
  * Supports switching the controlled actor cleanly (e.g., taking control of a mount or transformed form) so the same input pipeline can drive different actors and mappings without extra LocalScripts.

**Input Runtime & Client Action Runtime Clarifications (M0 Contract)**

* Input phases include: Pressed, Released, Held, LongHeld, DoubleTapped (threshold/window-based; Held/LongHeld are one-shot events on threshold crossing, not per-frame pulses).  
* Client requests are start/stop only: the client requests action start and stop through the framework’s validated request surface; the server remains authoritative on whether the request is accepted.  
* Explicit request acknowledgement for reconciliation: every client action request receives an explicit accept/reject response (with a reason code on rejection and a server-issued action instance identity when accepted) so prediction/reconciliation is deterministic.

**Game must do:**

* Define the game’s input actions and contexts (e.g., which actions exist in Gameplay\_Human vs Gameplay\_Monster vs Gameplay\_Mount) and decide when contexts should be activated or swapped (transformations, mounts, dialogue, menus).  
* Define control profiles that map input actions to framework actions per weapon/form/mount/stance and keep those mappings in data instead of scattering input handling across LocalScripts.  
* Tune input feel (hold thresholds, double-tap windows, buffering behavior) and any client-side prediction behavior to match the desired responsiveness and style of each game built on the framework.

## **System: Networking & Replication Core**

**Framework Provides:**

* A server-authoritative replication layer for framework state (tags, actions, and future framework systems), so gameplay state is always driven by the server, not clients.  
* An event driven server API: framework systems (Tag Runtime, ActionController, etc.) emit local “state changed” events (e.g., tag added/removed, action started/ended), and the Networking Core is responsible for turning those into network messages. Gameplay code never touches RemoteEvents directly for these systems.  
* Snapshot \+ delta replicator per actor:  
  * When a client first becomes aware of an actor, the core sends an initial snapshot of all client’s visible framework state for that actor  
  * After that only deltas are sent, keeping bandwidth predictable.   
* Client-side actor views that mirror the server state  
  * ActorView Objects expose read only snapshots (GetTags(), GetActions(), ect.) and subscribe style events (OnTagAdded/Removed/Updated) for UI, VFX, and client side animation and prediction  
  * Client code never interacts with remotes directly, only talks with these views  
* Filtering and visibility controls: tag and action definitions can mark which pieces of state are replicated to clients, allowing server-only tags/actions to exist without network cost.  
* Basic ordering and resync guarantees per actor:  
  * Clients see tags/action events in a consistent order for each actor  
  * The core can resend a full snapshot when needed, (on join or respawn) to recover from packet loss or desync

**Networking & Replication Clarifications (M0 contract)**

* Awareness policy (M0 scope choice): In M0, all registered Actors replicate to all players (no interest management / relevancy). This is an explicit M0 simplification, not a permanent default; later milestones may introduce configurable per-player relevancy without changing the core replication contract.  
* Actor identity: Replication is keyed by the Actor’s internal actorId. The initial snapshot provides enough mapping for the client to associate actorId with the replicated in-world Model for presentation/UI purposes.  
* Ordering \+ resync guarantee (per Actor): Clients observe tag/action updates for a given Actor as a consistent ordered stream. The core supports resync by re-sending a full snapshot for an Actor when needed (join/respawn/recovery), and the client ActorView must treat a snapshot as authoritative and reset its local view accordingly.  
* Visibility filtering: Tag and action definitions declare whether they are client-visible. Only client-visible tags/actions appear in snapshots/deltas and client ActorView events; server-only state is never replicated.  
* Client ↔ server contract: Clients do not replicate authoritative state (no client-driven tags/actions/health/etc.). Client→server messages are limited to validated framework request entrypoints (e.g., action requests) which the server may accept/reject with reason codes.  
* Optional high-frequency “presentation hints”: The networking layer may optionally support best-effort, non-authoritative client/server messaging for purely cosmetic data (e.g., aim/look direction) that can use unreliable delivery. These signals must never be treated as gameplay truth and must not directly produce real damage/tags/inventory/quest progress.

**Game must do:**

* Mark in tag and action definitions which pieces of state should be visible to clients (for UI/VFX/animation) and which should remain server-only.  
* Optionally trigger snapshot sends at appropriate times (e.g., when custom spawn/respawn logic is used) using the framework’s provided hooks, rather than manually serializing state.

## **System: Debug & Introspection Tools**

**Framework Provides:** 

* A global debug toggle (e.g., via a simple API call or console command) that turns framework debug visuals and logging on or off at runtime, without the game having to wire its own UI for it  
* A default in-world debug overlay for Actors when debug mode is enabled:  
  * Attaches a Billboard-style UI above each registered Actor’s root that shows key framework state (e.g., active tags, current visible action, and selected core properties such as resolved WalkSpeed).  
  * Updates automatically by reading from the same Actor views / introspection APIs used by normal gameplay systems (no extra networking paths).  
* A lightweight debug inspection API that exposes the same information programmatically for tools and developers (e.g., “dump this actor’s tags and actions to output” for quick diagnostics).  
* Simple extension points that let games register additional debug fields per Actor (e.g., AI state, faction, current target) so custom systems can piggyback on the same overlay instead of building separate debug UIs.

**Game must do:**

* Optionally register game-specific debug fields for Actors (AI state, quest state, weapon loadout, etc.) using the provided extension hooks if they want richer overlays during development.  
* Use the framework’s debug/introspection tools for diagnosing tag/action/actor issues rather than building parallel ad-hoc debug UIs for the same information.

## **System: Combat Resolution & Health / Knockdown**

**Framework Provides:**

* A single, server-side Damage Pipeline entrypoint (e.g., ApplyHit(damageContext)) that all framework and game systems use to apply damage, so health, shields, knockdown, and death are handled consistently in one place.  
  * damageContext always includes at least: sourceActor, targetActor, baseAmount, one or more damage types (e.g., Physical, Fire, etc.), and optional flags (e.g., unblockable, canCrit, bypassShield).  
* A structured pre/mitigation/post damage flow:  
  * Pre-mitigation hooks that can inspect/alter/cancel hits based on tags and state (e.g., State.Combat.InIFrames, Status.Invulnerable, Status.Blocking, Buff.Reflect).  
  * Integration with the property/stat system to apply defenses and resistances per damage type (e.g., PhysicalDefense, FireResist) before final HP change.  
  * Post-damage hooks for effects like lifesteal, on-hit procs, rage/meter gain, and for emitting events (OnDamageDealt, OnDamageTaken, OnDowned, OnExecuted, OnDied) that other systems (quests, XP, UI, AI) can subscribe to.  
* A standard health model for actors, with support for both:  
  * Direct death mode: when HP ≤ 0, the actor dies immediately.  
  * Opt-in Downed/Knocked mode: when enabled for an actor/game:  
    * HP ≤ 0 transitions the actor into a Downed state (e.g., via a tag like State.Downed) instead of immediate death.  
    * Movement/actions are restricted according to framework rules while downed.  
    * A configurable execution flow (finishers) and/or revive flow (ally interaction, item, timer) determines whether the actor actually dies or stands back up after a window expires.  
* A small set of built-in hitbox primitives for performing hit detection on the server (e.g., sphere, capsule, box) plus a registration mechanism to add custom shapes or behaviors.  
  * Each primitive is responsible for querying potential targets in the world and generating a list of hit results that are then passed into the Damage Pipeline, rather than applying damage directly.  
* Utilities for Actions to trigger hit detection in a consistent way (e.g., “during Active phase, cast a forward capsule and pipe any hits into the damage pipeline with this base damage context”), keeping Actions focused on when to hit and leaving how hits are resolved to the pipeline.

**Game must do:**

* Define the game’s damage types (e.g., Physical, Fire, Ice, Poison, True) and how they interact with stats/properties (e.g., which defenses/resistances exist and how they’re combined during mitigation).  
* Configure which actors and/or game modes use direct death vs Downed/Knocked behavior and plug in any custom execution/revive rules (timers, ally interactions, items, special finisher actions) using the provided hooks and events.  
* Use the framework’s hitbox primitives and utilities from within actions (or other systems) to perform hit detection, and always route resulting hits through the Damage Pipeline entrypoint instead of directly modifying HP or tags.

## **System: Movement & Mobility Runtime**

**Framework Provides:**

* A per-actor MovementController that is responsible for all framework-driven changes to Roblox Humanoid-based movement, including:  
  * Applying final movement-related Humanoid settings (e.g., WalkSpeed, JumpHeight/JumpPower) based on the current game-defined values and tag-driven modifiers.  
  * Owning and coordinating any BodyMovers / constraints used for movement features (dash, slide, glide, climb, flight, etc.) so multiple features don’t fight each other.  
* Integration with the Tag & Status Runtime for movement-related effects:  
  * Listens to tag/property-change events and updates Humanoid movement properties accordingly (e.g., Sprint / Slow / Rooted / Stunned affecting speed or jump).  
  * Keeps the actual Humanoid changes in one place (MovementController), while tags remain simple on/off states with optional movement multipliers.  
* Environment awareness for movement decisions, using raycasts/overlaps and/or designer-marked surfaces:  
  * Detecting ground/air state, slopes, simple ledges, and optional “special surfaces” (e.g., climbable walls, parkour nodes) that movement features can use.  
* A small set of built-in, opt-in movement features implemented on top of the MovementController and Action system:  
  * Core mobility: sprinting, directional dashing, double jumping.  
  * Advanced grounded moves (optional): crouch, slide, short ledge climb/vault.  
  * Verticality / fantasy moves (optional): wall climbing/scaling, basic flight/glide, and simple parkour-style jumps between tagged surfaces.  
* A clear server/client split for player movement:  
  * Server-side MovementController is authoritative for applying movement-related tags and Humanoid settings, reacting to combat (stun, knockback, downed), and fully controlling AI movement.  
  * For the local player, an client-side MovementController can perform higher-frequency environment checks and apply short-lived predicted movement operations (e.g., starting a dash or flight feeling instant), with reconciliation back to server state via the existing networking core.

**Game must do:**

* Decide which movement features/packs to enable globally or per actor (e.g., only some characters can wall-climb or fly) and configure the corresponding options in the framework.  
* Route movement-related gameplay through Actions \+ MovementController APIs (e.g., dash, sprint, climb, fly) rather than directly modifying Humanoid movement properties or inserting BodyMovers from ad-hoc scripts.  
* Provide any level markup or design hints needed for advanced movement (e.g., tagging climbable surfaces or parkour nodes) where raycast-only detection is not sufficient.

## **System: Items, Inventory & Equipment**

**Framework Provides:** 

* A global ItemDefinition registry where all items are defined in data, using a compositional model instead of inheritance. Each item has:  
  * Core Fields: ID, name, icon, description, rarity, maxStack, flags like isTradable, isSellable  
  * Optional components such as:  
    * Equippable (which slot(s) it can occupy: Weapon, OffHand, Armor, Accessory, Form, Mount, etc.).  
    * Weapon (links to a weapon action profile used by the Action system for core attacks).  
    * Armor / Passive (contributes tags and/or property modifiers while equipped).  
    * Consumable (references a useActionId the action system runs when the item is used).  
    * Movement Mod (declares movement-specific tweaks to merge into the Movement & Mobility runtime when equipped).  
    * Ability Bundle (declares one or more abilities / actions that may be bound into ability slots if the game opts into the Ability Loadout system).  
* A server-authoritative Inventory Runtime per actor that:  
  * Tracks what items the actor possess as a list of {itemId, quantity, instanceData?}, with stacking behavior driven by the ItemDefinition (maxStack, stackable flag).  
  * Provides APIs for adding/removing items, splitting/merging stacks, and transferring items between inventories (e.g., loot, trading, rewards).  
  * Exposes an event-driven replication layer so the client can keep a local view of the inventory for UI purposes.  
  * Keeps the data model simple and serialization-friendly so external persistence code (data stores) can easily save/restore inventories.  
* A per-actor Equipment Runtime that:  
  * Manages named equipment slots (e.g., MainHand, OffHand, ArmorChest, Accessory1, FormSlot, MountSlot) and which item (if any) is currently equipped in each slot.  
  * Handles equip/unequip operations in a consistent way (unequipping from one slot, returning items to inventory if needed).  
  * Integrates with other runtimes by firing standardized hooks on equip/unequip so:  
    * Tag & Status Runtime can apply/remove any tags the item grants while equipped.  
    * Movement & Mobility Runtime can apply/remove movement-related modifiers declared by the item.  
    * Action / ClientActionRuntime can adjust weapon profiles or grant/remove actions tied to the item.  
* An optional Hotbar mapping layer for items (separate from ability slots) that:  
  * Lets games map specific inventory items (typically consumables or utility items) to a small set of hotbar slots.  
  * Exposes a clean “use item from slot” API that internally routes through the Action system (via an item’s useActionId or a generic UseItem action).

**Game must do:**

* Define all ItemDefinitions in data, including which components each item uses (Equippable, Consumable, Weapon, Passive, MovementMod, AbilityBundle, etc.) and any game-specific metadata (rarity, lore, flavor text).  
* Decide the inventory model (size limits, whether it’s grid-based or list-based) and which equipment slots exist for the game’s characters.  
* Build any UI for inventory, equipment, and item tooltips, wiring it to the framework’s Inventory/Equipment/Hotbar APIs and events rather than manipulating underlying data directly.  
* Implement higher-level game logic around item acquisition and loss (loot tables, quest rewards, crafting, drop on death, etc.), using the Inventory/Equipment APIs instead of custom ad-hoc data structures.  
* Implement persistence using the inventory’s serialization-friendly structures (save/load item lists, equipment, and hotbar assignments) in the game’s own data storage layer.

## **System: Ability Loadout Runtime (Optional)** 

**Framework Provides:**

* Per-acotr Ability Loadout Runtime that manages slot-based abilities (spells, jutsu, special skills) separately from core controls:  
  * Supports configurable number of ability slots(default 5 slots Ability1-Ability5), with the ability for games to add or remove slots as needed.  
  * Maintains separate loadout banks per context/form (e.g., Human form vs Monster form vs Mount), so the same slots can mean different actions depending on form or gameplay context.  
* A simple data model mapping ability slots to Action IDs:  
  * For each actor and context: slotId (e.g., "Ability1") → actionId or nil.  
  * Exposes APIs such as BindAbility(slotId, actionId), UnbindAbility(slotId), LoadAbilitySet(setId), and GetActionForSlot(slotId).  
* Integration with the ClientActionRuntime so that:  
  * When an input action corresponding to a slot (Ability1–AbilityN) is triggered, the ClientActionRuntime can delegate to the Ability Loadout (if enabled) to resolve which ActionId should be requested from the ActionController.  
  * Changes to the loadout (e.g., equipping an item that grants new jutsus, or a quest unlocking a new spell) raise events that UI and other systems can observe to refresh ability bars.  
* Optional support for Ability Sets as a convenience layer:  
  * Each Ability Set is a Named group of actions (e.g., a Fire Style set) that can be loaded into slots in one operation.  
  * Item components (e.g., AbilityBundle) or progression logic can reference these sets rather than binding each slot manually.

**Game must do:**

* Decide whether to opt in to the Ability Loadout system. Games that prefer only core controls and weapon-class actions can ignore this system entirely.  
* If using it, define:  
  * How many ability slots are available and which input actions (e.g., Ability1–Ability5) map to them.  
  * Any Ability Sets used by items, classes, or quests (e.g., Fire Style sets, spell books, stance-specific move sets).  
* Implement game logic that modifies the loadout in response to progression, items, or story:  
  * e.g., learning a new jutsu, equipping a release item that fills slots 1–5, or unlocking a single additional slot.  
* Build any UI for ability bars / loadout management (drag-and-drop slots, per-form views, etc.) using the loadout APIs and change events exposed by the framework.

## **System: Shop Runtime (Optional)**

**Framework Provides:**

* A server-side Shop Runtime that:  
  * Validates buy requests:  
    * Confirms the shop and item entry exists and are currently available (e.g., checks optional stock limits or requirements).  
    * Delegates to a game-provided currency abstraction to confirm the buyer can afford the purchase.  
    * Uses the inventory Runtime to grant the purchased items if all checks pass  
  * Validates sell requests (if enabled):  
    * Confirms the player actually owns the items being sold.  
    * Computes the sell value  
    * Adjusts currency and inventory accordingly   
  * Exposes a clean Remote/Event-facing API for clients to request buys/sells, with well-defined success/failure responses suitable for UI feedback  
* Integration with the Inventory Runtime so that all changes to player items from shops go through the same consistent inventory paths used elsewhere

**Game must do:**

* Provide the game’s currency/resource model (e.g., Gold, Ryo, Credits) and implement the functions the Shop Runtime calls to check and modify those values.  
* Define all ShopDefinitions in data (which items are sold where, base prices, any stock limits or requirements).  
* Build the shop UI (lists, categories, previews) and wire it to the framework’s shop API for buy/sell requests and responses.  
* Decide any additional economic rules (price scaling, discounts, dynamic stock, reputation, etc.) and, if needed, extend or wrap the base Shop Runtime to support those rules.

## **System: Quest & Objective Runtime**

**Framework Provides:**

* A data-driven QuestDefinition registry where all quests are defined in data rather than code. Each quest can specify:  
  * Basic metadata (id, name, description, category/arc).  
  * Optional requirements (level, prerequisite quests, tags/flags, etc.).  
  * One or more stages, each with one or more objectives and a stage completion rule (e.g., complete all objectives vs complete any).  
* A per-player, server-authoritative Quest Runtime that:  
  * Tracks quest state per player (available, active, completed, failed) and per-quest stage and objective progress.  
  * Listens to generic gameplay events from other frameworks systems (combat, actions, movement, items, dialogue), such as:  
    * OnEnemyDefeated, OnActorDamaged, OnActionCompleted, OnItemAdded, OnRegionEntered, OnDialogueChoicePicked, etc.  
  * Uses these events to drive objective progress for a small set of built-in objective archetypes, including but not limited to:  
    * Defeat/kill objectives with flexible filters (by enemy type, faction, tag, region).  
    * Collect objectives (items, drops, quest items).  
    * Interaction/objectives (talk to NPC, interact with world object, trigger region).  
    * Sequence/route objectives (visit checkpoints/regions in order, optionally under a time limit).  
  * Exposes an event API when objectives or quests progress/complete so other systems (rewards, progression, UI) can react.  
* Built-in support for constraint-based quests so games can define “style rules” and more advanced archetypes on top of basic objectives:  
  * A generic constraint layer that can enforce rules over the duration of a quest or stage, such as:  
    * Forbidden actions or action groups (e.g., “no ranged attacks”, “no healing”, “no items”).  
    * Limits on damage taken, deaths, or resource usage.  
    * Equipment/slot restrictions (e.g., “no heavy armor”, “two-handed weapon only”), expressed via tags or item metadata.  
    * Movement or traversal rules (e.g., “reach the checkpoints without touching forbidden regions”).  
  * The constraint engine listens to the same gameplay events and marks constraints as kept or broken; the quest runtime can treat broken constraints as failure conditions or as optional bonus conditions.  
* Optional support for contract / risk–reward quests:  
  * A simple ContractDefinition concept that bundles one or more constraints with reward modifiers.  
  * The ability for a quest to offer one or more contracts at start (e.g., “no healing”, “time limit”), with the quest runtime tracking which were honored and providing this information to the reward/progression layer.  
* A replication-friendly quest state view for clients:  
  * Per-player summaries of active quests, their stages, and high-level progress so UI can render quest logs, markers, and hints.

**Game must do:**

* Author QuestDefinitions in data (including stages, objectives, and any constraints/contracts to use), using the provided archetypes for basic quests (kill/collect/talk/travel) and extending via filters and events for more advanced patterns (style duels, movement trials, contract modifiers).  
* Provide any game-specific identifiers and event wiring needed for objectives and constraints (e.g., mapping “enemy type” to your enemy system, defining region/trigger ids in the world, ensuring combat/movement actions emit the standard events).  
* Build all player-facing quest UI (log, tracker, world markers, contract-selection screens) and connect it to the quest runtime’s replicated state and events.  
* Implement the game’s reward and progression logic that runs when quests or optional constraints/contracts are completed (XP, currency, items, unlocks, reputation, etc.), using the quest runtime’s completion results and any constraint/contract metadata.  
* Implement persistence of quest state (active quests, stage/objective progress, and any associated flags) in the game’s own data storage layer, using the simple structures exposed by the quest runtime.

## **System: Dialogue Runtime**

**Framework Provides:**

* A data-driven DialogueDefinition model for authoring conversations with NPCs or interactable entities including:  
  * Dialogue nodes (speaker, text key, optional animation/VO cues).  
  * Choices per node, each with:  
    * A label text key.  
    * A target node or an end-of-conversation marker.  
    * Optional conditions (e.g., quest state, tags/flags, progression state) that control visibility or availability.  
    * Optional effects that fire when the choice is selected.  
* A server-authoritative Dialogue Runtime that:  
  * Orchestrates dialogue sessions between a player and an NPC/entity:  
    * Starting a conversation based on a DialogueDefinition id and optional context.  
    * Determining which node and which choices are valid for the player given current quest/progression state and conditions.  
    * Advancing to the next node when a choice is selected, and cleanly ending the conversation when appropriate.  
  * Applies choice effects in an integrated way with other framework systems, such as:  
    * Starting or advancing quests and quest stages via the Quest Runtime.  
    * Granting or removing items via the Inventory Runtime.  
    * Opening shops or trade interfaces via the Shop Runtime.  
    * Unlocking actions/abilities or updating input bindings (e.g., teaching Dash or granting a new spell) via the action/input/loadout layer.  
    * Setting or clearing generic flags/tags that other systems or future dialogues can check.  
* A clean client API/protocol for driving dialogue UI:  
  * The server sends down the current node (speaker \+ text key) and the list of valid choices (with choice ids and label keys).  
  * The client presents these however it wants (dialogue box, visual novel UI, etc.) and sends back “choice picked” messages.

**Game must do:**

* Author DialogueDefinitions in data, including all nodes, choice texts, conditions, and effects, using the provided hooks into quests, items, shops, and progression where needed.  
* Decide the UI/UX for dialogue (layout, portraits, animations) and connect it to the dialogue runtime’s start/advance APIs and messages.  
* Define any game-specific condition and effect helpers needed to integrate dialogue with custom systems (e.g., clan/faction alignment, reputation thresholds, custom story flags).  
* Ensure that NPCs or interactive objects in the world know which DialogueDefinition to use when the player interacts with them, and under what conditions dialogue should be available (e.g., proximity, quest state, time of day).  
* Implement persistence for any long-lived story flags or state that dialogues set, outside of quests (e.g., faction allegiances, relationships), if the game requires them.

## **System: World Interaction & Trigger Runtime (Optional)**

**Framework Provides:**

* A lightweight, server-authoritative World Interactable system for things like NPCs, chests, levers, shrines, doors, training dummies, etc.:  
  * A simple component/registry to give world objects an interactableId and optional kind (e.g., Talk, Use, Loot, Train, Teleport).  
  * A single interaction entrypoint: the client uses the Input Runtime’s Interact action to request interaction with an interactableId; the runtime validates distance/visibility/cooldowns/conditions on the server.  
  * When valid, raises a standard event such as OnInteract(player, interactableId, kind) that other systems (Dialogue, Quests, Shops, Trials, Teleports) can subscribe to, instead of each implementing their own RemoteEvents and proximity checks.  
* A data-driven Region / Trigger Volume subsystem for zones in the world (e.g., parkour checkpoints, boss arenas, defense points, safe zones):  
  * Definitions for region/trigger ids and shapes (referencing Parts or simple box/sphere volumes), plus what kinds of actors they care about (players, enemies, any actor).  
  * A runtime that tracks overlaps and emits standard events such as OnRegionEntered(regionId, actor), OnRegionExited(regionId, actor), and, where configured, OnRegionCountChanged(regionId, count) or simple timed/“stay inside” events.  
  * Designed to feed higher-level systems like Quest objectives (movement trials, defense missions), dungeon/trial logic, cutscenes, and AI behavior zones using the same event surface.

**Game must do:**

* Decide which world objects are interactables, assign them ids/kinds, and subscribe to OnInteract events to perform game-specific behavior (start dialogue, open a shop, pull a lever, start a training trial, teleport the player, etc.).

* Define regions/triggers in the world (by placing parts or configuring volumes), give them semantic ids, and subscribe to region events to drive quests, movement trials, boss arenas, defense objectives, or other custom logic.  
* Build and style all player-facing UI for interaction prompts and region indicators, wiring it to the Input Runtime’s Interact action and the interaction/region events exposed by this runtime.  
* Implement any game-specific access rules or conditions beyond the basics (e.g., only clan members can interact with a sect altar, only players with a certain quest stage can activate a shrine), using hooks/conditions provided by the interactable and region definitions.  
* Opt out entirely if desired: games that prefer fully custom interaction logic can bypass this system and handle world interactions on their own.

## **System: AI & Behavior Runtime**

**Framework Provides:**

* Perception Snapshot (per actor)  
  * A lightweight perception layer for NPC-controlled actors that maintains a periodically updated snapshot of relevant world facts, such as:  
    * Nearby enemies and allies (with basic info like distance, relative direction, simple tags such as IsDowned, IsCharging, etc.).  
    * Relevant regions/triggers (e.g., defense points, checkpoints, danger zones) from the World Interaction & Trigger Runtime.  
    * Basic threat/aggro hints (e.g., who damaged this NPC recently, who is currently targeted).  
  * Exposes this as  a read-only blackboard to AI logic so decision making code does not perform raw raycasts or ad-hoc queries  
* Per-NPC AI Controller using Behavior Profiles	  
  * A per-actor AI controller that decides what that NPC should do next by:  
    * Owning a BehaviorProfile that describes that NPC’s overall style (e.g., brawler, ranged, evasive, supporter) and tuning knobs (aggression, caution, reaction delays, mistake rates, etc.).  
    * Evaluating a set of Intents (e.g., “BasicMeleeCombo”, “RangedPoke”, “Dodge”, “RetreatToRange”, “ProtectAlly”) against the current perception snapshot and computing a utility/score for each.  
    * Selecting an intent that passes preconditions and has the highest utility, then issuing requests through the existing ActionController and Movement & Mobility Runtime instead of driving combat/movement directly.  
  * Ensures AI uses the same action/movement systems as players (e.g., requests actions by actionId, uses movement primitives like chase/keep distance/orbit) so behavior feels like a “skilled player” rather than a separate ruleset.  
* Difficulty & Style Tuning  
  * BehaviorProfiles expose configurable knobs so games can build AI that wins through behavior, not just inflated health/damage, including (examples, not exhaustive):  
    * Per-event reaction delays (e.g., typical response time to big, telegraphed attacks vs quick jabs).  
    * Mistake rates / imperfection factors for defense and offense so easier AIs occasionally fail to punish or misjudge ranges.  
    * Style weights (pressure vs zoning vs evasive vs support) and risk tolerance (how often to use unsafe but high-reward actions).  
    * Optional adaptation flags so AIs can gradually favor certain Intents when the player repeats patterns (e.g., whiffing big moves, always opening with the same combo starter).  
  * The framework provides the structure for these knobs; exact values and behaviors are game tuned per enemy type and difficulty.  
* Optional Squad / Encounter Coordination  
  * An optional SquadCoordinator layer that can manage small groups of NPCs and assign them roles and high-level directives, enabling behaviors such as:  
    * “Honor duels”: only one active Duelist truly engages while others orbit, taunt, or lightly harass.  
    * Coordinated squads: leaders, flankers, ranged units, and tanks that position and act in complementary ways instead of all independently rushing the player.  
  * Coordinators communicate through tags / simple role flags (e.g., SquadRole.Duelist, SquadRole.Support, SquadRole.Ranged), which individual AI Controllers read to bias their Intent weights appropriately.  
  * Supports AI vs AI encounters naturally since both sides use the same actor/action/movement systems.  
* Optional Encounter / Spawn Runtime  
  * A lightweight Encounter/Spawn helper for open-world style content:  
    * Encounter definitions (e.g., “post” or “zone” templates) that specify spawn locations, NPC types/BehaviorProfiles, maximum active count, spawn/despawn radii, and respawn rules.  
    * A runtime that spawns/despawns NPCs as players enter/leave these encounter radii, wiring them automatically to AI Controllers, BehaviorProfiles, and optional SquadCoordinators.  
  * Keeps spawning logic consistent with data-driven rather than hard coded per place in the world  
* Authority & Presentation Modes  
  * AI decisions (which action to use, when to attack, when to dodge, when to retreat) and all gameplay outcomes (tags, damage, health, death, quest progress, drops) are always server-authoritative, routed through the ActionController, Combat Resolution, Tags, and other server-side systems.  
  * The AI & Movement/Animation integration supports two presentation modes for NPCs:  
    * Server-driven mode: server drives movement and replication directly for tighter security or competitive scenarios.  
    * Client-assisted mode (opt-in): server sends high-level movement/action intent for NPCs, and selected clients drive smooth local movement and animations for those NPCs using the Movement & Mobility Runtime and Animation Runtime. The server still validates actions and damage, and can correct excessive divergence, but clients handle most of the visual/positional smoothing to achieve more responsive, “non-Roblox-y” feeling AI in PvE/open-world contexts.

**Game must do:**

* Define BehaviorProfiles for each enemy type/difficulty (and optionally per boss phase), including:  
  * which Intents they have available,  
  * how those Intents are scored in different situations,and tuning values for aggression, caution, reaction delays, mistake rates, and style preferences.  
* Implement the Intent logic for game-specific behaviors (which actionId to request, how to pick targets, what movement primitive to request) within the structure provided by the AI controller, rather than directly manipulating tags or internal action state.  
* Optionally define Squad/Encounter configurations:  
  * squad compositions and role rules (honor duels, focused fire, support behavior),  
  * encounter/spawn points and rules for when NPCs appear/disappear.  
* Decide, per encounter or per NPC type, whether to use server-driven or client-assisted movement/animation presentation, understanding the trade-offs between feel and security, and hooking into the Movement & Mobility Runtime and Animation Runtime accordingly.  
* Provide any game-specific perception filters or additional facts that the AI should consider (e.g., faction/family relationships, special objective targets, environmental hazards) and ensure these are exposed through the perception snapshot rather than ad-hoc queries.  
* Build any AI-specific debug tools or visualizations on top of the core Debug/Introspection tools (e.g., overlays that show current Intent, target, squad role, and perceived threats) if deeper tuning/inspection is desired.

## **System: Animation & Presentation Runtime**

**Framework Provides:**

* A client-side, per-actor PresentationController that is responsible for how an actor’s state is visually represented (animations and VFX), without affecting game logic. It:  
  * Listens to replicated framework events (Action lifecycle, Tag add/remove/expire, Combat damage/knockdown, Movement state changes) and to explicit “preview” hooks from the ClientActionRuntime.  
  * Maps these events into animation and effect playback using data-driven definitions  
* A data-driven Animation & Effect Registry, where games can define:  
  * Which animation(s) play for each action phase (e.g., Sword\_LightCombo\_1.Startup, Sword\_LightCombo\_1.Hit, Knockdown\_Loop, Downed\_StandUp).  
  * Which VFX bundles are attached to which events (e.g., Status.OnFireApplied → looping fire on torso; Action.Fireball.Cast → charge-up FX; Damage.Fire\_Hit → impact spark).  
  * Optional timing metadata (e.g., when to emit hit VFX relative to an animation marker or normalized time).  
* Prediction and reconciliation hooks integrated with the Input Runtime & ClientActionRuntime:  
  * When ClientActionRuntime requests an action, it can ask the PresentationController to start a predicted animation/VFX sequence immediately, before the server confirms.  
  * When the server accepts/rejects or later interrupts the action, the PresentationController reconciles:  
    * confirming and continuing the animation/effects,  
    * or cancelling, blending out, or snapping to an appropriate fallback if the prediction was wrong.

**Game must do:**

* Define the actual Animation & Effect data for the game:  
  * Register animation sets and their mapping to framework events (per action, per weapon/form, per movement state, per tag).  
* Define VFX bundles (particles, beams, trails, sounds) and how they attach to characters/objects for each relevant event.  
* Provide any style-specific rules for presentation (e.g., blending between stances, camera shakes for certain hits, slow-motion on finishing blows) using the hooks and events exposed by the PresentationController.  
* Decide where and how to preload animations and VFX assets to avoid runtime hitches, using the registry as the source of what needs to be preloaded for each context/encounter.  
* Wire the game’s UI or additional visual layers (e.g., hit stop flashes, screen FX on low health) to the same Presentation/Combat events if desired.  
* Opt out or partially use this system if they want a fully custom animation/VFX approach; the framework does not require the Presentation Runtime for core logic, it only standardizes and simplifies the common case.

# **5\. Core guarantees and quality bar**

This section defines what the framework must always guarantee. If any of these are violated, it is considered a bug in the framework or how it’s being used.

## **5.1 Authority and Single Source of Truth**

* Server-authoritative gameplay: All real gameplay outcomes (health, tags/status, knockdown/death, inventory, currency, quest state, AI decisions, etc.) are decided and mutated only by server-side framework controllers (ActionController, Tag Runtime, Combat Resolution, Inventory Runtime, Quest Runtime, etc.).  
* No bypassing core entrypoints: Any change to core state must go through the documented APIs (for example: RequestAction, ApplyHit, AddTag/RemoveTag, AddItem/RemoveItem, AdvanceQuest). Directly modifying Humanoids, HP, tags, inventories, or quest structures outside these paths is unsupported.  
* One source of truth per concern:  
  * Movement-related Humanoid settings and movement BodyMovers are owned by the Movement & Mobility Runtime.  
  * Health and knockdown/death are owned by the Combat Resolution & Health/Knockdown system.  
  * Status effects/buffs/debuffs are owned by the Tag & Status Runtime.

## **5.2 Networking and Consistency**

* Consistent replicated state per actor: For each actor, clients receive tag/action/health changes as an ordered stream per actor, plus initial and recovery snapshots. Snapshot \+ delta replication must keep client ActorViews in a valid, self-consistent state.  
* Framework owns network plumbing: Core framework systems (Tags, Actions, Combat, Movement, Inventory, Quests, AI) never expose raw RemoteEvents or RemoteFunctions. Game code talks to controllers and client-side views; the Networking & Replication Core is the only layer that touches remotes for framework state.  
* Prediction is cosmetic only: Client-side prediction (movement, animations, VFX, local input feel) can never directly create real damage, tags, inventory, or quest progress. When the server disagrees, clients reconcile to server state via the provided mechanisms.

## **5.3 API Shape and Extensibility**

* Registry \+ controller pattern everywhere: Major systems expose data registries (TagRegistry, ActionRegistry, ItemRegistry, QuestRegistry, DialogueRegistry, BehaviorProfiles, and so on) for definitions, plus per-actor controllers/views for runtime behavior. Games extend via these registries and public APIs, not by reaching into internal tables.  
* Data-driven with validation: Definitions for tags, actions, items, quests, dialogue, AI behavior profiles, etc. are data-first. The framework performs basic validation on load (or at usage time) and logs clear errors when configuration is invalid, rather than silently failing.  
* Optional systems are truly optional: Opt-in systems (Ability Loadout, Shops, Quests, Dialogue, World Interaction, AI, Animation & Presentation) can be entirely unused without breaking the core runtime. Their absence should not affect core combat/movement functionality.

## **5.4 Performance and Scale Expectations**

* Work scales with active gameplay, not place size: Tag ticking, action updates, AI evaluation, and quest/objective checks are proportional to active actors, active tags, and active quests/objectives, and avoid per-frame full-world scans where possible.  
* Reasonable defaults for typical anime RPG servers: Default settings and implementations are expected to handle a typical anime/RPG server (dozens of active combatants, normal amounts of tags/hits/quests per player) without pathological CPU or network usage, assuming sane game-side content.  
* No unbounded per-frame client loops: Client runtimes (Input, ClientActionRuntime, ActorViews, Presentation) avoid per-frame heavy iteration over all actors. Expensive work is event-driven, timed, or batched.

## **5.5 Debuggability and Developer Experience**

* Inspectable actor state at runtime: It must always be possible, using the framework’s debug and introspection tools, to inspect any actor and see at least: active tags and remaining durations, current actions/high-level action state, current health and downed/dead state, and resolved core movement properties (for example, effective WalkSpeed and JumpHeight).  
* Debug overlay reflects real replicated state: The default debug overlay and inspection APIs read from the same ActorViews and controllers that gameplay systems use, no separate debug-only state paths.  
* Framework failures are observable: Misconfigurations (unknown IDs, missing definitions, invalid quest/objective wiring, etc.) surface as clear, actionable logs or warnings in development builds, rather than silent no-ops.

# **6\. Design principles (framework laws)**

These are the guiding rules for how the framework is designed and implemented.

* The server is always authoritative for gameplay, but every system is designed assuming client-side prediction and smooth local feel for players.  
* Tags, actions, items, quests, dialogue, AI behavior profiles, etc. are defined in data/registries; code reads definitions and applies generic rules instead of hardcoding game specifics.  
* Items, actors, quests, and behaviors are built from small, composable components and flags, not deep class trees or “God objects.”  
* There is exactly one public entrypoint to do each core thing (apply damage, start an action, apply/remove tags, modify inventory, advance quests). If you bypass it, you are outside the framework contract.  
* A small core (actors, tags, actions, networking, movement/combat basics) is always on; higher-level systems (ability loadouts, shops, quests, dialogue, AI, presentation) are additive and can be opted into per game.  
* The framework never encodes specific universes or progressions (“chakra”, “realms”, “classes”, “ranks”); it exposes neutral building blocks that games can theme and combine however they want.  
* All runtimes expose introspection APIs and emit events so developers can see what the framework thinks is happening (on actors, tags, actions, AI, etc.) without ad-hoc logging everywhere.  
* Luau types and clear interfaces are used wherever possible so misuse is caught early, and registries/controllers are understandable from their type signatures and public methods alone.

# **7\. Architecture overview**

## **Per Actor Stack**

![][image1]

# **8\. Testing, tooling, and CI expectations**

## **8.1 Tooling Baseline**

* Source of truth for framework code is a Rojo-Structured repository  
* Version control will be through git and Github  
* A Lua Test running (maybe TestEZ) that can run both in and out of studio  
* Formatter / Linter (stylua or selene)

## **8.2 Testing Expectations**

* Core framework systems must have automated Unit and Integration tests for the contract behavior  
* Tests should favor small, deterministic “logic” tests over full Studio simulations where possible  
* Where cross-system behavior is critical (e.g., an Action applying a tag which then modifies Movement, or a Dialogue choice granting an item and advancing a quest), add a few focused integration tests that simulate the minimal wiring between those systems.

## **8.3 Continuous Integration (CI)**

* Every push to the main branch must run and pass:  
  * Full automated test suite  
  * Linting and formatting checks  
* CI should:  
  * produce clear outputs for failures  
  * Build / Export packaged artifacts for the framrwork from the rojo project for easy consumption

## **8.4 Local Developer Workflow**

* Workflow looks like the following:  
  * Make change   
  * Run test locally   
  * Sync via Rojo in a sample place  
  * Manual sanity check  
  * Push / Open PR

# **9\. Versioning, compatibility, and migration**

## **9.1 Versioning Scheme**

* This framework uses semantic versioning in the form MAJOR.MINOR.PATCH  
* While in 0.x, MINOR bumps (0.x → 0.y) may include breaking changes, but they must still be documented with migration notes.  
* Once the framework reaches 1.0.0:  
  * PATCH (x.y.z → x.y.(z+1)) \= bug fixes and internal changes only; no breaking changes.  
  * MINOR (x.y.z → x.(y+1).0) \= backward-compatible features, deprecations, and improvements.  
  * MAJOR ((x.y.z → (x+1).0.0)) \= may introduce breaking changes and removals.

## **9.2 Deprecation Strategy**

* Public APIs and features are never removed without first being marked as deprecated.  
* Deprecation must include:  
  * A clear note in documentation / comments  
  * A runtime warning in development environments when the deprecated API is used (ideally once per session per API)  
  * A note in the changelog under a “Deprecated” section  
* Deprecated APIs remain available for atleast:  
  * One MINOR version in 0.x or until the next MAJOR version once the Framework is 1.x  
* Internal/private helpers used only inside the framework are not guaranteed a deprecation period; only documented public contracts are

## **9.3 Migration Expectations**

* Every release that introduces breaking changes must:  
  * Document them in a dedicated Breaking changes section of the changelog  
  * Update a MIGRATION.md with step-by-step guidance, grouped by systems  
* Where practical, breaking changes should be introduced with short-lived shims  
* When designing changes, the framework should prefer:  
  * Additive changes and new options over signature changes  
  * Renames via aliases/shims rather than outright replacement  
* Migration guides should include small, concrete before/after code examples for any non-trivial change  
* Test coverage should be updated as part of migration so that the new behavior is enforced and regressions are less likely

## **9.4 Branching and Release Workflows**

* Git branching model remains intentionally simple:  
  1. Main-always green and releasable; tagged with version numbers  
  2. Short lived branches for changes, named by type and scope ex:  
     * feature/action-buffering  
     * fix/inventory-stack-bug  
     * docs/charter-cleanup  
* All changes are merged into main via pull requests after:  
  1. Automated tests pass  
  2. Linting / format checks pass  
  3. Any relevant migration notes and changelog entries are added  
* Release Process for a new version:  
  1. Update the version in the designated version file / metadata  
  2. Update CHANGELOG.md and MIGRATION.md  
  3. Ensure main is green  
  4. Tag the release commit as vX.Y.Z

# **10\. Roadmap and milestones**

This roadmap sequences the major “end-to-end layers” of the framework. Detailed epics/stories (and any deeper criteria) live outside the charter.

* M0-Core Runtime Spine  
  * Actor / Character Runtime  
  * Tag & Status Runtime  
  * Action System / ActionController  
  * Input Runtime & ClientActionRuntime  
  * Networking & Replication Core  
  * Debug & Introspection Tools  
  * Animation & Presentation Runtime (animations, VFX, sounds; prediction \+ reconciliation hooks)  
* M1-Gameplay Core  
  * Movement & Mobility Runtime  
  * Combat Resolution & Health / Knockdown  
* M2-RPG & Content Layer  
  * Items / Inventory / Equipment  
  * Ability Loadout Runtime (Optional)  
  * World Interaction & Trigger Runtime (Optional)  
  * Quest & Objective Runtime  
  * Dialogue Runtime  
  * Shop Runtime (Optional)  
* M3-Advanced / Expansion Systems  
  * AI & Behavior Runtime  
  * Squad / Encounter Coordination (Optional)  
  * Encounter / Spawn Runtime (Optional)  
  * Client-assisted AI presentation mode (Optional)