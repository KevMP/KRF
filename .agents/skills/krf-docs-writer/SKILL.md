---
name: krf-docs-writer
description: Write, revise, review, or plan documentation for Kevin's Roblox Framework (KRF), including product guides, University lessons, manual API reference, examples, docs-site navigation, and documentation PRs. Use for any change under docs-site/docs or when translating KRF source and runtime contracts into consumer-facing documentation. Enforces source-grounded accuracy, useful API semantics, KRF system boundaries, canonical examples, and clear separation between guides, lessons, reference, and contributor material.
---

# KRF Docs Writer

Write for Roblox developers building games with KRF. Do not write for the person who implemented KRF, and do not translate tickets into prose.

The documentation should let a consumer answer three questions without reading source:

1. Which KRF system should own this state or behavior?
2. What is the correct way to use it?
3. What does the runtime guarantee when it succeeds, fails, changes, or is destroyed?

## Ground every change in the repository

Before writing or approving documentation:

1. Read the relevant public types and implementation.
2. Read tests for edge cases, ordering, failure behavior, and lifecycle guarantees.
3. Read adjacent concept and API pages to avoid contradictions and duplication.
4. Inspect the Docusaurus sidebars and links when adding, moving, or renaming pages.
5. Compare documentation against the current branch, not an issue's proposed API.

Issues and PRs explain intent, but merged source defines the current public contract. If source, tests, and docs disagree, identify the disagreement instead of silently choosing one.

Never invent an accessor, bootstrap API, controller registration helper, error reason, event payload, or lifecycle guarantee. Do not describe planned systems as if they exist.

## Classify the page first

### Documentation

Consumer guides under `docs-site/docs/documentation` explain concepts, ownership, decisions, and canonical workflows.

A good guide helps a developer design game code correctly. It is not a tour of every member on a module.

### University

Lessons teach KRF progressively through explanation, guided work, exercises, and checkpoints. They may repeat a small amount of reference information when necessary for learning.

### Manual API reference

Pages under `docs-site/docs/api` are the precise consumer contract for a supported public surface. They explain not only what members are named, but how to call them correctly and what their observable behavior is.

### Contributor or repository documentation

Build commands, source organization, testing infrastructure, release processes, and contribution workflows belong in repository-facing documentation, not product guides or API reference.

## Separate the product from the repository

Public KRF docs may describe runtime behavior and durable design rationale. They must not expose:

- story ids, milestones, acceptance criteria, or ticket history
- test names or statements such as “the tests prove”
- internal helper modules or file-by-file implementation tours
- temporary migration details or design churn
- test-only hooks and bootstrap plumbing that consumers do not call
- speculative future members or systems

Translate implementation rationale into a durable contract:

- Internal: “This was added because re-entrancy broke the second signal.”
- Public: “Destroying the controller from an event listener prevents later events in the same operation.”

## Documentation pages

### Required outcome

A concept page should establish:

- the problem the system solves
- what state or responsibility it owns
- what adjacent systems own instead
- the normal lifecycle or usage flow
- the important guarantees and constraints
- at least one concrete usage pattern when code clarifies the concept
- mistakes a reasonable KRF consumer might actually make
- where to go for exact API details

Do not force every page into identical headings. Choose headings that fit the concept. “What this is / What this owns / What this does not own” is acceptable when boundaries are genuinely the main lesson, but repeated boilerplate is not a substitute for explaining the system.

Prefer a coherent explanation followed by a concrete flow. Use tables when comparing exact concepts such as base versus resolved values, static versus property-backed sources, or `Spend` versus `Drain`.

### Depth standard

Do not stop after restating names from the type definition. Explain consequences.

Weak:

> Resources may have property-backed maximums.

Useful:

> A property-backed maximum is resolved through the actor's `PropertyController`. KRF seeds the property only when it is missing, preserves an existing base value, and clamps the resource's current value when the resolved bound decreases.

Document behavior that changes how consumers design code, including:

- ownership and authority
- construction and teardown
- registration or assignment timing
- mutation and clamping semantics
- atomicity and rollback
- event timing and ordering when public
- static versus live state
- base versus resolved state
- failure behavior that callers must handle

Avoid padding pages with obvious statements or generic Roblox advice.

### Examples

Use examples to demonstrate the canonical pattern, not to inventory methods.

Examples must:

- use only APIs present on the current branch
- show how the consumer actually obtains the module, actor, or controller
- include `--!strict` for complete files
- use typed locals where they improve clarity
- handle a meaningful failure when failure is part of normal usage
- omit unrelated setup
- use realistic KRF names and gameplay scenarios
- remain short enough that the relevant behavior is obvious

Do not copy tests into docs. Tests arrange internals that consumers should not need.

## API reference

An API page is a lookup surface. A developer landing on one method should be able to call it safely without opening source or a concept guide.

“Bias toward API shape” means keep information local and scannable. It does not mean stripping away semantics.

### Decide whether the surface is public

Include a module or member only when game code is expected to call, observe, or type against it. Omit:

- private helpers
- test reset functions and test toggles
- framework-only wiring
- members exposed accidentally by a returned table
- lifecycle operations consumers should never invoke directly, unless documenting them is necessary to prevent misuse

Documentation is a support commitment. If a low-level module is public but rarely appropriate, say who should use it and identify the preferred higher-level entrypoint.

### API page opening

Open with two or three sentences that establish:

- what the surface represents
- how consumers obtain it
- whether it is a normal gameplay entrypoint or lower-level infrastructure

Do not add an import block to actor-owned controllers that consumers normally obtain through `actor:GetController(...)`. Show acquisition instead. Add an import block for modules consumers directly require.

### Document every public method with local semantics

Use this structure when applicable:

~~~md
### `Spend(resourceId, amount) -> (boolean, string?)`

Pays an all-or-nothing resource cost. `amount` must be a finite, non-negative number.

| Parameter | Type | Description |
| --- | --- | --- |
| `resourceId` | `string` | Assigned resource to spend. |
| `amount` | `number` | Value to subtract if the full cost is available. |

Returns `true, nil` after payment. Returns `false, reason` without changing the resource when the resource is missing, the amount is invalid, or the available value above the resolved minimum is insufficient.
~~~

For simple zero-argument getters, a parameter table adds noise; a precise sentence is enough. Use judgment rather than mechanically repeating tables.

For each method, document the applicable parts:

- purpose and when to use it
- parameters, including units and valid ranges
- return meaning, not just return types
- mutation or lack of mutation
- clamping, atomicity, ordering, or idempotency
- relevant failure categories or stable reason strings
- side effects and emitted events
- ownership or lifecycle restrictions

Do not list every internal error string when callers cannot act differently. Do list stable reasons when callers reasonably branch on them or when the exact string is already part of the supported contract.

Never write only “Sets the value,” “Returns the value,” or “Reports whether…” when constraints or behavior exist.

### Document events as observable contracts

For every public event, specify:

- exactly what causes it to fire
- what does not cause it to fire when that distinction matters
- when it fires relative to the mutation
- the payload, with named fields or parameters
- any ordering consumers may rely on

Prefer a payload table or typed record plus a short semantics paragraph.

Weak:

> Fires when a resource changes.

Useful:

> Fires after the current value or resolved bounds change. Assignment alone does not fire it. Mutations that clamp to the existing current value also do not fire it.

### Types and definitions

Do not paste a large nested type and leave the reader to reverse-engineer its invariants.

For authored definitions:

1. Show the canonical type shape.
2. Explain each field in a field table.
3. State defaults, exclusivity rules, valid values, and units beside the relevant field.
4. Provide one realistic definition example.

Extract repeated nested types such as `ResourceNumericSource` into their own named section rather than duplicating anonymous shapes.

For snapshot or change records, show the type and explain semantics that are not obvious from field names.

### Suggested API page shape

Use only sections that add value:

1. title and role
2. import or acquisition
3. authored definitions or key types, when consumers construct or inspect them
4. methods
5. events
6. short usage example, only when member entries do not show the interaction clearly
7. related guide and adjacent reference links

Do not use a generic `Notes` section as a dumping ground. Put each contract detail beside the member or type it governs. A page-level lifecycle or safety section is appropriate when it applies to the whole surface.

## University pages

A lesson should include:

- a specific learning outcome
- the prerequisite mental model
- progressive steps that build one working understanding
- a small exercise or modification
- a way to check understanding
- a clear next lesson

Do not turn API reference into a lesson, or a lesson into an exhaustive API catalog.

## KRF voice

Use concise, direct, concrete language. KRF should sound cohesive, opinionated, and safe.

Prefer:

- “KRF registers an Actor before enabling its controllers.”
- “`Spend` is atomic; failure leaves the current value unchanged.”
- “The registry freezes normalized definitions after a successful load.”

Avoid:

- powerful, robust, seamless, flexible
- unlock the potential
- whether you are a beginner or an expert
- generic claims that could describe any framework
- repeatedly beginning sentences with “This allows…”
- overusing bold text to manufacture emphasis

Use KRF's established terminology and capitalization: Actor, controller names in code formatting, server-authoritative, actor-scoped, base value, resolved value, definition, instance, and runtime state.

## KRF positions to preserve

- KRF is actor-centric, not ECS-first.
- KRF owns hard runtime lifecycle decisions.
- Registries own static definitions; controllers own live actor state.
- KRF favors durable contracts over temporary convenience.
- Current resource values are not properties.
- Tags modify properties; Property Runtime resolves final numeric values.
- Examples show canonical patterns rather than every possible pattern.
- Concept guides and API reference complement one another instead of duplicating one another.

## Validation

Before finalizing a docs change:

### Accuracy

- Every documented member exists on the current branch.
- Signatures, payloads, defaults, units, and failure behavior match source and tests.
- No internal or test-only surface is presented as supported API.
- Planned behavior is clearly absent rather than written in future tense as a promise.

### Usefulness

- A consumer can tell when to use the system.
- Important ownership boundaries and lifecycle rules are explicit.
- API entries explain constraints and observable behavior, not merely names.
- Authored definitions explain field invariants and include a realistic example.
- Events explain triggers, non-triggers, timing, and payloads.

### Information architecture

- Guides teach decisions and flows; API pages support exact lookup.
- Links use the site's actual routes and resolve from the page location.
- Sidebars include new pages in the intended order.
- Nearby pages do not contradict or needlessly duplicate the change.
- Terminology is consistent across titles, sidebars, guides, reference, and source.

### Presentation

- Headings describe the content rather than repeat a rigid template.
- Code blocks are valid Luau and use current APIs.
- Tables are used for exact mappings, not decorative layout.
- The page is scannable without being shallow.
- The production docs build succeeds when the change affects the site.

## Review mode

When reviewing documentation, report concrete findings in priority order. Cite the page and the inaccurate, missing, misplaced, or weak contract. Distinguish factual defects from quality improvements.

Pay particular attention to:

- stale statements after runtime changes
- source signatures paraphrased without semantics
- missing validation and failure behavior
- events documented without timing or non-trigger behavior
- examples that bypass canonical KRF ownership
- concept pages that read like type inventories
- API pages that are too thin to replace source reading
- repeated template headings that make every system sound identical
- incorrect links, sidebar placement, and terminology