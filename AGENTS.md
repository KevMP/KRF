# KRF repository instructions

## Repository hygiene

- Use conventional branch prefixes such as `feat/`, `fix/`, `docs/` or `chore/`;
  never use `codex/`.
- Do not commit TDD plans, historical red-phase baselines, one-off engineering
  reports or investigation diaries. Keep temporary evidence in ignored local
  directories (such as `build/`), PR descriptions or GitHub issues.
- Do not commit raw benchmark results, logs, coverage artifacts or
  machine-specific evidence. Keep reproducible fixtures and workflow instructions.
- Remove generated starter files that serve no current purpose. Before adding
  standalone scripts or tooling, check and reuse existing workflows where practical.
- Permanent documentation explains current contracts, usage, maintenance or
  contributor workflows, rather than retelling a ticket's implementation.

## Follow the established system structure

Before adding or reorganizing a system, inspect the comparable Actor, Controller,
Tags and Property modules. Use these as concrete references:

- `src/server/Actor/ActorRuntime.luau` and `ActorRegistry.luau`
- `src/server/Controller/ControllerRegistry.luau`
- `src/server/Tags/TagController.luau` and `utils/TagControllerEvent.luau`
- `src/server/Property/PropertyController.luau` and `utils/PropertyRecompute.luau`

Organize source by execution side and system: `src/<side>/<System>/`.

- Keep primary runtime, controller, registry, validator and codec modules at the
  system root. Small systems do not need an empty helper directory.
- Put cohesive implementation collaborators in lowercase `utils/`: capture/diff
  plans, scheduling, recipient projection, lifecycle bridges, event plumbing,
  discovery, platform adapters and similar helpers. A helper does not become a
  primary system module merely because another system or a test imports it.
- Do not flatten implementation helpers into the system root or organize source
  by ticket number, milestone or implementation phase.
- Keep system ownership explicit. Public client ActorView contracts belong to
  `client/Actor`; Networking's stream/application machinery belongs to
  `client/Networking`. Shared source must not depend on server/client runtimes.
- Follow the existing structure before inventing another directory layer. Split
  a new system only when it has a distinct responsibility and lifecycle.

## One type module per system folder

- Use exactly one lowercase `types.luau` for cross-module system contracts.
  Do not add sibling files such as `PublicationTypes.luau`, `AwarenessTypes.luau`,
  `ProtocolTypes.luau` or other `*Types.luau` files alongside it.
- Give exported contracts descriptive names when several concerns share a type
  module: `PublicationRuntime`, `ActorAwarenessOptions`, `ResyncRuntime`, and
  `ActorStreamConsumer`, rather than multiple ambiguous `Runtime`/`Options` types.
- Keep implementation-local types next to their implementation. A helper may
  export its own private record/plan/context types, as Property and Tags already
  do; do not create a separate type-only file for that helper.
- Type modules may require other type modules but must not require runtime
  implementations. Avoid self-requires and circular type dependencies.
- Require each type module once per file. Reuse that namespace instead of
  importing the same module repeatedly under aliases for individual concerns.
- Give implemented runtime receivers genuine internal state types. Do not use
  `self: any` or cast constructors to `any` to bypass checking private fields.
  Schema-erased payloads and opaque identity keys may retain their contract types.

## Public views and private ownership

- Freeze public lookup facades and mark their methods `read` in public types.
  Keep installation, mutation, indexes and writable Signals in framework-private
  owners. A public Event must not expose its owning Signal.
- Establish ActorView and DomainView ownership before implementing Networking
  coordination. ActorView owns identity, Model and visible domains; DomainView
  owns immutable state, change/semantic events and teardown. Networking owns
  revision validation, recovery and atomic publication across those owners.
- Separate state installation from notification. All affected state and indexes
  must be installed before the runtime fires any public notification.

## Structural refactors

- Keep requires static and at the top of the module. Follow existing Luau path
  conventions, use descriptive local names and explicit KRF object types, and
  retain `--!strict`.
- Update every affected consumer in the same refactor: source, tests, fixtures,
  integration scripts, project configuration, tooling and written path references.
- Remove obsolete private module paths. Do not leave compatibility shims,
  duplicate implementations or duplicate type declarations to disguise a move.
- Preserve behavior, public contracts and test assertions during an organization
  change. Do not implement unrelated features or hide failing tests in a refactor.
- Source helpers use lowercase `utils`; test helper folders use the existing
  capitalized `Utils` convention. Keep focused specs named
  `Module.Behavior.spec.luau`; tests need not mirror every source helper directory.

## Validation and quality

- Read the applicable repository skills before editing tests or documentation.
- Run `npm run test:unit` for test changes and `npm test` before completion.
  Formatting/lint and Luau type checks must pass. Do not reduce coverage limits,
  skip tests or change runner selection to make a refactor appear successful.
- For an intentionally red TDD branch, compare with its local or issue/PR baseline.
  Preserve expected missing-behavior failures and all previously passing tests;
  module-loading, require-path, syntax, type and fixture failures are regressions.
- Native networking contracts need real server/client coverage alongside injected
  unit integration tests. Exercise normal startup and consumer installation,
  actual transports, privacy and teardown; never replace the consumer installer
  in the fixture intended to prove that installation works.
- Build systems to production quality. Milestone scope is not permission for
  shortcuts, temporary architecture or deferred cleanup.
- Preserve unrelated user changes. Commit only work belonging to the request.
