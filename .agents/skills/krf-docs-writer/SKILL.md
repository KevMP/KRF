---
name: krf-docs-writer
description: Write, revise, review, or plan KRF consumer documentation, examples, manual API reference, and docs-site navigation. Use for changes under docs-site/docs or when translating KRF contracts into guidance. Enforces source-grounded accuracy, framework-aware examples, and concise consumer-first writing.
---

# KRF Docs Writer

Write for Roblox developers building games with KRF. Help them find the owning system, use its supported entrypoint, and understand the guarantees that affect their code.

## Ground examples in the whole framework

- Read `CHARTER.md` for ownership and product direction. It includes planned systems and superseded descriptions; it does not prove an API ships.
- Read current public types and implementation, then relevant tests for validation, failures, ordering, and teardown.
- Audit each example against adjacent systems, not only the page's system. Trace ownership of state, validation, payment, lifetime, replication, and cleanup.
- Read nearby guides and API pages for contradictions and duplication. Inspect config, routes, and sidebars when changing navigation.
- Describe the current branch. If source, tests, and docs disagree, identify the mismatch rather than silently choosing one.

Never invent an accessor, registration helper, bootstrap API, failure reason, payload, or lifecycle guarantee. Never present planned systems as available to make an example complete.

## Teach idiomatic KRF

An example must teach the pattern a game should adopt, not merely code that could run.

| Concern | Canonical owner or pattern |
| --- | --- |
| Actor creation and teardown | `ActorRuntime`; registry lookup is not lifecycle ownership |
| Static definitions | Game catalogs loaded by startup; registries provide lookup |
| Actor state | The owning controller, acquired through `actor:GetController(...)` |
| Stamina, Mana, Guard, other meters | Resources; never a custom meter controller or numeric Property |
| Action eligibility and payment | Grants, Tag/Resource requirements, and declarative `costs` |
| Action-owned status | `activeTags` for owned lifetime, `appliedTags` for effects with their own lifetime |
| Numeric modifiers | Tags contribute modifiers; Property Runtime resolves values |
| Framework replication | Networking and client views; no parallel remotes or copied framework systems |
| Game-specific extensions | Custom controllers/domains for state not already owned by a framework system |

For ordinary Action costs, use `costs`. Do not teach manual `CanSpend`/`Spend` checks before a request or inside hooks. `resourceRequirements` checks conditions beyond affordability and does not spend. Costs are paid once on acceptance, not per update. If discussing ongoing or outcome-dependent policies, state that boundary without inventing recurring-cost metadata or making manual spending the default recipe.

Direct Resource methods remain valid for other game-driven changes. Choose examples whose intent does not suggest bypassing Actions. Do not compensate for a missing built-in replication surface with a custom Stamina controller/domain or claim `ClientVisible` alone publishes state; inspect the actual domain builder and client contracts.

Preserve the charter's other boundaries: KRF is Actor-centric; registries hold definitions and controllers hold live state; current resource values are not properties; movement application and combat/health have their own ownership. When a system is absent, say so instead of implementing it in an example.

## Keep ordinary usage first

The intended consumer experience is template-first, with initialization already handled. Do not claim a starter template exists without verifying it on the current branch.

- System guides assume an initialized game and focus on definitions, controller access, or view consumption.
- Keep manual `Server.Init`/`Client.Init` integration on the initialization page. Link there instead of repeating startup scripts, failure reporting, transport discovery, or consumer installers.
- Show catalog modules returning definitions, or clearly labeled definition fragments. Direct registry `Load` calls are not the normal guide workflow.
- Include imports/acquisition where needed; identify assumed inputs such as an already registered Actor.
- Use `--!strict` for complete files, useful types, current ids, and ordinary failure handling. Omit unrelated setup.
- Never copy test fixtures, injected dependencies, private observer seams, or framework bootstrap wiring into ordinary consumer examples.
- Prefer removing a misleading walkthrough to building a replacement tutorial outside the request's scope.

For focused pre-M0 cleanup, correct misleading patterns, trim duplication, and improve task discovery within existing pages. Preserve guarantees and accurate references. Defer the full documentation overhaul and tutorial track until after M0 unless the user changes scope; do not redesign the site or add APIs to support documentation.

## Choose the page's job

| Page | Purpose |
| --- | --- |
| Guide | Ownership, canonical workflow, decisions, and consequential guarantees |
| University lesson | One progressive outcome, with prerequisites, exercise, checkpoint, and next lesson |
| API reference | Exact supported callable and observable surface |
| Contributor docs | Repository layout, tooling, tests, and contribution workflows |

Do not turn guides into member inventories, API pages into tutorials, or consumer pages into implementation tours. Do not publish placeholder lessons; state that the track is unavailable or omit it from navigation when supported setup is missing.

## Write compact consumer guidance

- Open with one or two sentences identifying the surface and its role. Put the common task or supported entrypoint early.
- Explain consequences that change consumer code: authority, assignment, validation, failures, atomicity, events, and teardown.
- Use tables for choices, ownership, payload fields, and exact mappings; numbered lists for meaningful lifecycle order.
- Keep one idea per paragraph. Link to the canonical explanation instead of repeating it on every page.
- Use code to show supported usage, not source declarations. Do not paste `export type` blocks, alias inventories, or complete interface definitions into guides or references. Explain supplied fields, defaults, callback inputs/results, and payloads in concise prose or field tables; retain useful method and callback signatures. Avoid full controllers or listener managers to demonstrate a small concept.
- Remove generic setup, motivational copy, repeated summaries, and repeated “what it owns / does not own” sections.
- Preserve consequential guarantees: no partial payment, no automatic refunds, immutable views, installation before notification, recovery, privacy, and cleanup.
- Put uncommon ordering or protocol detail after common usage or on the existing advanced page. Complexity alone is not a reason to delete a contract.

No rigid word limit applies. Stop when the reader can make the decision or use the surface safely.

Public docs must not expose story ids, milestones, test names, internal helper tours, design churn, test hooks, or speculative members. Translate implementation details into observable contracts: “Destroying the controller from an event listener prevents later events in the same operation.”

## Manual API reference

Include surfaces game code is expected to call, observe, or type against. Exclude private helpers and accidentally exposed members. Label supported but rarely appropriate low-level surfaces **Infrastructure API** and point to the preferred entrypoint.

Open with one sentence and a compact import or acquisition block. Obtain Actor-owned controllers through `actor:GetController(...)`; do not require their implementation for normal game use.

Reference pages act as symbol browsers:

- Begin with a **Members** index, grouped by member kind where useful.
- Show complete linked signatures, with stable explicit anchors on detailed headings.
- Give each member its full typed signature, one purpose sentence, and stable failure returns when callers branch on them.
- Give each event its complete signature and triggering condition.
- Keep defaults, units, payloads, and failure names exact. Do not omit information needed to call a member safely.
- Keep workflows, definition-field guidance, formulas, timing/ordering analysis, and examples in the matching guide. Signatures and typed usage examples may reference public type names without reproducing their source declarations.
- End with relevant guide and adjacent-reference links.

Do not add generic API landing/conventions pages, standalone type sections, or “at a glance” tables that paraphrase member names instead of showing signatures. Preserve existing accurate reference surfaces during editorial cleanup.

## Voice

Use direct, concrete language and established names: Actor, base value, resolved value, definition, instance, runtime state, and controller names in code formatting. Explain what happens rather than praising the framework. Avoid generic marketing adjectives, repeated “This allows,” and bold text used only for emphasis.

## Validate before finishing

- Recheck changed examples across all systems they touch: real APIs, ownership, catalogs, assignment/grants, payment, lifetime, and cleanup.
- Distinguish supported behavior from template intent and unavailable systems; do not invent availability to fill a gap.
- Confirm signatures, failure returns, event order, and guarantees against source and tests.
- Search the docs for removed ids, examples, anchors, and paths; repair affected links and consumers.
- Check neighboring pages for contradictory recommendations, needless repetition, and copied type declarations. Do not preserve a source dump merely because its fields are accurate.
- Run the production docs build and applicable repository checks. Report failures without weakening checks.
- Validate skill changes with the skill-creator validator when available.
- Report what was corrected and what remains deliberately deferred, without adding roadmap promises to consumer pages.

In review mode, report factual defects before editorial improvements, with page locations. Prioritize non-idiomatic examples, wrong ownership, unsupported APIs, missing guarantees, setup presented as ordinary usage, and broken links.
