# N2 TDD contract

Source: [issue #72](https://github.com/KevMP/KRF/issues/72).

The feature branch now implements the codec, global protocol catalog, owned
transport, server handshake, and client initialization contracts. The original
red-phase specifications remain executable, with additional hostile-input,
native-adapter, lifecycle, and startup rollback coverage. Actor replication,
awareness, commands, and unreliable gameplay semantics remain outside N2.

## Decisions and ambiguities

- **Optional collection entries:** N1 allows Optional Array elements and Map
  values, but ordinary Luau tables cannot preserve a nil entry. The user chose
  to reject absent Optional collection entries during decode. Present entries
  remain valid. Optional Struct fields and top-level nil values remain valid.
  Decode rejects the entire collection with `CodecCollectionEntryAbsent` rather
  than introducing a sentinel, an Array hole, or an omitted Map entry.
- **All-or-nothing server startup:** Networking preparation runs before any
  startup registry is published. A later Networking activation failure leaves
  all registries unpublished and removes only framework-owned transport state.
  Publication rollback also covers failures in any of the five registries.
- **Ready ordering:** The server marks the connection ready before sending
  READY_ACK. Private Ready observers run after that acknowledgement is sent,
  so publication triggered by an observer follows it on the reliable lane.
  The client installs private protocol consumers before sending READY.
- **Failure spelling:** Client repeat-attempt failures use `system = "Client"`.
  Transport, bootstrap and handshake failures use `system = "Networking"`.
  The tests adopt the ticket's named failure categories. Codec validation keeps
  existing N1 reasons; malformed wire values have codec-specific reasons.
- **Repeated HELLO:** While AwaitReady, duplicate HELLO packets are ignored.
  They do not resend bootstrap, send repeated rejections, restart compilation,
  add connection state, or interfere with the original READY transition.
- **Bounded rejections:** Reject carries one message-kind byte and one code from
  the framework-owned `RejectionReason` enum. Arbitrary diagnostic strings and
  unknown reason codes are rejected; a Reject packet is exactly two bytes.
- **N1/N2 size compatibility:** A codec's `maxSizeBytes` cannot exceed its N1
  schema's `maxEncodedBytes`. Legal bounds above U32 remain exact in both state
  and event descriptors throughout server manifest generation and bootstrap.
  Tests cover odd bounds above 2^40 and 2^52, `MAX_SAFE_INTEGER - 8`, and an
  empty-Struct Array whose cardinality reaches `MAX_SAFE_INTEGER` itself.
  The eight-byte allowance matters for N1 encoded-size admission; enormous
  legal maximum sizes are tested using small runtime values, not giant buffers.
- **Private choices:** Internal module names, transport paths, packet opcodes,
  numeric code assignments, prefix widths and timeout/budget defaults are not
  consumer API. Internal seams can be refined while preserving the behavior
  assertions. The bootstrap descriptors carry semantic
  schema definitions, separate from server callbacks and compiled size metadata.
- **Collection work admission:** Measure/Write and Read apply the same private
  root budget to total collection entries, including nested zero-byte records.
  Large legal descriptor bounds remain supported without permitting a tiny
  packet to trigger unbounded materialization. Budget failure is atomic for
  writes, and each operation starts with a fresh budget.

The ticket's buffer-only bootstrap decision explicitly supersedes N1's earlier
permission to use a structured bootstrap; that is not a conflict. Likewise,
readiness before ACK and observer notification after ACK describe distinct
steps and are compatible. Server-only built-in definition projection remains
N6–N8 work; N2 consumes only the explicitly provided domain protocol catalog.

## Test locations

| Area | Specs |
| --- | --- |
| Codec values, validation, hostile decode, shared buffers | `tests/shared/Networking/Codec.*.spec.luau` |
| Symmetric collection-work admission and budget isolation | `tests/shared/Networking/Codec.WorkBudget.spec.luau` |
| Buffer framing and client manifest reconstruction | `tests/shared/Networking/Protocol.*.spec.luau` |
| Closed reason codes and fixed-size rejection packets | `tests/shared/Networking/Protocol.Rejections.spec.luau` |
| Roblox Instance ownership and collisions | `tests/shared/Networking/Transport.spec.luau` |
| Deterministic global catalog and bootstrap projection | `tests/server/Networking/Protocol.Codebooks.spec.luau` |
| Large legal N1 bounds preserved through bootstrap | `tests/server/Networking/Protocol.SchemaBounds.spec.luau` |
| Server readiness, gating, lifecycle, multi-client reuse | `tests/server/Networking/ServerHandshake.spec.luau` |
| Observer reentrancy, unsubscribe, yielding/throwing callbacks, send failures | `tests/server/Networking/ServerHandshake.Lifecycle.spec.luau` |
| Native event wiring, departed players, readiness proxies, activation cleanup | `tests/server/Networking/ServerNetworking.Transport.spec.luau` |
| Startup preparation, rollback, failure observability | `tests/server/Server/Init.Networking.spec.luau` |
| Late registry publication failures and complete rollback | `tests/server/Server/Init.Rollback.spec.luau` |
| Client ordering, one attempt, timeouts and cleanup | `tests/client/Client.Init.Handshake.spec.luau`, `Client.Init.Failures.spec.luau` |
| Unexpected startup exceptions and consumer cleanup | `tests/client/Client.Init.Errors.spec.luau` |
| Native discovery, event adapter, deferred resume, timer cancellation | `tests/client/NativeClientDependencies.spec.luau` |
| Real protocol modules bridged across isolated clients | `tests/client/Client.Init.Integration.spec.luau` |

The protocol client fixture supplies a controlled clock, timeout callback and transport.
Tests resume initialization in a coroutine and deliver protocol messages
explicitly, including immediate responses during sends. Two cloned client
modules provide separate one-attempt state while sharing protocol modules.

## Validation

Run `npm run test:unit` during implementation and `npm test` for final validation.
Do not skip the new specs or lower coverage thresholds to hide the red phase.

The native adapter tests exercise platform scheduling and bindable event wiring;
the protocol fixtures isolate per-client state. These unit tests do not emulate
RemoteEvent delivery across separate engine processes. Caller-owned buffer tests
prove direct-write composition; they do not measure allocator activity or CPU
performance.

An additional two-client fixture lives in `tests/integration/Networking`. Build
it from the repository root:

```powershell
rojo build networking-test.project.json -o KRF-Networking-Tests.rbxl
```

Open that place in Studio in **Edit mode**, then run the contents of
`scripts/run-networking-tests.luau` from the command bar or a local plugin.
`StudioTestService:ExecuteMultiplayerTestAsync` has plugin security and requires
the edit DataModel. `run-in-roblox` runs in a simulation DataModel and cannot
launch this particular check. The fixture ends the test with structured results;
success prints `__KRF_NATIVE_NETWORKING_PASS__`.

The tested automated launch uses a local plugin built from
`networking-test-plugin.project.json`:

```powershell
rojo build networking-test-plugin.project.json -o build/KRF-Networking-Test-Plugin.rbxmx
```

Copy that file into the Studio local Plugins directory, then launch Studio with
the integration place. The plugin starts only in Edit mode when it finds the
fixture's `NetworkingTestControl` RemoteEvent. It prints the structured result
to Studio's Output and log. Remove this temporary plugin after the run. Waiting
for `game.Loaded` is unsuitable in the edit DataModel; the launcher instead
waits briefly for the fixture marker.

The fixture checks actual `Client.Init` and native discovery on both clients,
identical codebooks, buffer delivery, ACK-before-follow-up ordering, no server
recompilation or domain callback execution, and readiness removal when one
client leaves. Its extra `NetworkingTestControl` remote is test-only and is
separate from the two framework transports. The follow-up marker is test data,
not an Actor publication implementation.

Validation status: `npm test` passes all 1,254 tests across 87 suites, including
the existing per-file coverage thresholds. The production Docusaurus build
passes. The live two-client Studio check also passes through the Edit-mode
plugin: two Ready clients, one Closed client, six server codec compilations,
and zero domain callback calls. The temporary plugin was removed afterward.
