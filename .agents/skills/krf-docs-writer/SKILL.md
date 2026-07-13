---
name: krf-docs-writer
description: Write, revise, review, or plan documentation for Kevin's Roblox Framework (KRF), including product guides, University lessons, manual API reference, examples, docs-site navigation, and documentation PRs. Use for any change under docs-site/docs or when translating KRF source and runtime contracts into consumer-facing documentation. Enforces source-grounded accuracy, concise information design, useful API semantics, KRF system boundaries, and clear separation between guides, lessons, reference, and contributor material.
---

# KRF Docs Writer

Write for Roblox developers building games with KRF. The docs must answer, without requiring source inspection:

1. Which KRF system owns this state or behavior?
2. What is the supported way to use it?
3. What does the runtime guarantee on success, failure, change, and teardown?

## Ground every claim in the repository

Before writing:

1. Read the public types and implementation.
2. Read tests for validation, failure behavior, event order, and lifecycle edges.
3. Read adjacent guide and API pages for contradictions and duplication.
4. Inspect Docusaurus config, sidebars, and routes when navigation changes.
5. Describe the current branch, not proposed or ticketed behavior.

Source defines the current public contract. Tests clarify observable behavior. If source, tests, and docs disagree, identify the mismatch instead of silently choosing one.

Never invent an accessor, bootstrap API, registration helper, error reason, payload, or lifecycle guarantee. Do not describe planned systems as available.

## Classify the page before editing

| Page type | Job | Default shape |
| --- | --- | --- |
| Guide | Explain ownership, decisions, and a canonical workflow. | Short summary, ownership map, flow, focused example, pitfalls, API links. |
| University | Teach one outcome progressively. | Outcome, prerequisite, guided work, exercise, checkpoint, next lesson. |
| API reference | List the exact callable and observable surface. | Acquisition/import, members, properties or methods, events, related links. |
| Contributor docs | Explain repository work. | Commands, source layout, testing, release, and contribution workflows. |

Do not turn a guide into a member inventory, an API page into a tutorial, or public docs into repository notes.

## Write for scanning first

KRF docs should be compact without being vague.

- Open with one or two sentences that identify the surface and its role.
- Put the most useful contract before background or rationale.
- Prefer tables for exact mappings, options, ownership boundaries, and payload fields.
- Prefer numbered lists for lifecycle and event order.
- Keep paragraphs to one idea; split after three sentences unless continuity clearly helps.
- Use examples only when they demonstrate a supported pattern that prose cannot show as clearly.
- Link to exact API details instead of repeating full signatures in guides.
- Delete generic setup, motivational copy, obvious Roblox advice, and repeated summaries.

Do not apply a rigid word limit. A page is done when a consumer can make the relevant decision or call the surface safely. Extra prose after that point is a defect.

## Keep product docs free of repository history

Public KRF docs may describe runtime behavior and durable design rationale. They must not expose:

- story ids, milestones, acceptance criteria, or ticket history
- test names or statements such as "the tests prove"
- internal helper modules or file-by-file implementation tours
- temporary migration details or design churn
- test-only hooks and bootstrap plumbing
- speculative future members or systems

Translate implementation history into an observable contract. For example: "Destroying the controller from an event listener prevents later events in the same operation."

## Guides

A guide should establish only what a consumer needs to design code correctly:

- the problem and owning system
- adjacent system boundaries
- the normal lifecycle or workflow
- design-relevant guarantees and constraints
- one focused pattern when code is useful
- realistic mistakes
- links to exact reference pages

Use a compact ownership table when several systems interact. Use a comparison table for concepts such as definition versus instance, base versus resolved, static versus property-backed, or `Spend` versus `Drain`.

Explain consequences, not names.

Weak: "Resources may have property-backed maximums."

Useful: "A property-backed maximum resolves through the actor's `PropertyController`. Assignment seeds the property only when missing, preserves an existing base value, and clamps current value when the resolved bound falls."

Prioritize behavior that changes consumer code:

- ownership and authority
- construction and teardown
- registration or assignment timing
- validation, mutation, and clamping
- atomicity and rollback
- event timing and ordering
- static versus live state
- base versus resolved state
- actionable failure behavior

### Guide examples

Examples must:

- use APIs present on the current branch
- show how consumers obtain the module, actor, or controller
- include `--!strict` for complete files
- use typed locals where they improve clarity
- handle ordinary failure paths
- omit unrelated setup
- use realistic KRF names
- keep the relevant behavior visually obvious

Never copy test arrangement into consumer docs.

## Manual API reference

An API page is a lookup surface. A developer landing on one member must be able to use it safely without reading source or a guide.

### Select supported surfaces deliberately

Include a module or member only when game code is expected to call, observe, or type against it. Omit private helpers, test hooks, framework-only wiring, and accidentally exposed table members.

If a low-level surface is supported but rarely appropriate, label it **Infrastructure API** near the top and point to the preferred entrypoint.

### Open with acquisition, not an essay

Use two short blocks:

1. one sentence defining the surface
2. an import block for directly required modules or an acquisition block for actor-owned controllers

Do not give actor-owned controllers an import example when normal game code gets them from `actor:GetController(...)`.

### Member contract

API entries are intentionally compact:

1. Show the complete typed signature.
2. State the member's purpose in one direct sentence.
3. List stable failure returns only when callers branch on them.

Move workflows, examples, lifecycle explanation, timing, ordering, formulas, authored type shapes, and design guidance to the matching guide.

### API page navigation

API navigation should resemble a technical symbol browser, not a guide summary.

- Do not add a generic API landing or conventions page when the sidebar already exposes the available surfaces.
- Open the API section on the first real reference surface.
- Begin each surface with a compact **Members** index.
- Group the index by member kind when applicable: properties, methods, and events.
- Types are not API pages or API sections. Signatures may reference public type names, but the API reference does not reproduce or explain their shapes.
- Show the complete linked signature in each row. Add at most one short contract phrase when it materially distinguishes similar members.
- Use stable explicit anchors on detailed member headings so index links and the right-side table of contents remain durable.
- Keep detailed member contracts below the index and let the generated table of contents act as the page's symbol rail.

Do not use an "At a glance" purpose table that paraphrases member names without showing their signatures.

### Events

For every public event, specify:

- the complete event signature
- one sentence stating what causes it to fire

Do not add event timing or ordering analysis to API pages. Put those contracts in the corresponding guide.

### API page ending

End with only relevant guide and adjacent-reference links. API pages do not include examples, standalone type sections, concept sections, lifecycle walkthroughs, formulas, or timing sections.

## University lessons

Every lesson needs:

- one explicit learning outcome
- prerequisite knowledge
- progressive guided work
- a small exercise or modification
- a checkpoint with an observable result
- a next lesson

Do not publish placeholder lessons. If the product lacks the supported setup needed for a lesson, state that the track is not yet available or omit it from navigation.

## KRF voice

Use concise, direct, concrete language. KRF should sound cohesive, opinionated, and safe.

Prefer:

- "KRF registers an Actor before enabling its controllers."
- "`Spend` is atomic; failure leaves current value unchanged."
- "The registry freezes normalized definitions after a successful load."

Avoid:

- powerful, robust, seamless, flexible
- unlock the potential
- whether you are a beginner or an expert
- generic claims that describe any framework
- repeatedly beginning sentences with "This allows"
- bold text used only for emphasis
- repeated "What this is / owns / does not own" templates when a table is clearer

Use established terms: Actor, controller names in code formatting, server-authoritative, actor-scoped, base value, resolved value, definition, instance, and runtime state.

## KRF positions to preserve

- KRF is actor-centric, not ECS-first.
- KRF owns hard runtime lifecycle decisions.
- Registries own static definitions; controllers own live actor state.
- Current resource values are not properties.
- Tags modify properties; Property Runtime resolves final numeric values.
- Examples show canonical patterns, not every possible pattern.
- Guides and API reference complement rather than duplicate one another.

## Validation

Before finalizing:

### Accuracy

- Every member exists on the current branch.
- Signatures, payloads, defaults, units, failure behavior, and event order match source and tests.
- No internal or test-only surface is presented as supported API.
- Planned behavior is absent, not promised in future tense.

### Usefulness

- A consumer can identify the owning system and supported entrypoint.
- Guides make lifecycle and ownership decisions explicit.
- API entries expose complete signatures and concise member purposes.
- API pages contain no standalone type documentation or examples.
- Events expose complete signatures and concise triggers.

### Information architecture

- Guides teach decisions and flows; API pages support exact lookup.
- Links use real site routes.
- Sidebars include pages in the intended order.
- Nearby pages do not contradict or needlessly duplicate the change.
- Titles, sidebars, guides, source, and API pages use consistent terms.

### Presentation

- Openings are short and content starts quickly.
- Tables and lists replace repetitive prose where they improve scanning.
- Import or acquisition blocks are valid Luau and use current APIs.
- The production docs build succeeds.

## Review mode

Report findings in priority order with page locations. Separate factual defects from editorial improvements. Look especially for stale runtime statements, undocumented public surfaces, missing validation and event semantics, non-canonical examples, concept pages that inventory types, API pages that require source reading, repeated template headings, bad links, and inconsistent terminology.
