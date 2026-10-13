# N2 TDD contract

Source: [issue #72](https://github.com/KevMP/KRF/issues/72).

This change supplies typed internal contracts, unimplemented module stubs, and
executable Jest-Lua specifications. New behavior is intentionally red. Existing
server startup behavior is unchanged; `Server.Init` integration is specified by
tests and still needs implementation. `N2NotImplemented` is a scaffold marker,
not a final startup failure reason.

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
  The existing startup pipeline must be extended to honor this contract.
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
  consumer API. The stubs propose internal seams that can be refined while
  preserving the behavior assertions. The bootstrap descriptors carry semantic
  schema definitions, separate from server callbacks and compiled size metadata.

The ticket's buffer-only bootstrap decision explicitly supersedes N1's earlier
permission to use a structured bootstrap; that is not a conflict. Likewise,
readiness before ACK and observer notification after ACK describe distinct
steps and are compatible. Server-only built-in definition projection remains
N6–N8 work; N2 consumes only the explicitly provided domain protocol catalog.

## Test locations

| Area | Specs |
| --- | --- |
| Codec values, validation, hostile decode, shared buffers | `tests/shared/Networking/Codec.*.spec.luau` |
| Buffer framing and client manifest reconstruction | `tests/shared/Networking/Protocol.*.spec.luau` |
| Closed reason codes and fixed-size rejection packets | `tests/shared/Networking/Protocol.Rejections.spec.luau` |
| Roblox Instance ownership and collisions | `tests/shared/Networking/Transport.spec.luau` |
| Deterministic global catalog and bootstrap projection | `tests/server/Networking/Protocol.Codebooks.spec.luau` |
| Large legal N1 bounds preserved through bootstrap | `tests/server/Networking/Protocol.SchemaBounds.spec.luau` |
| Server readiness, gating, lifecycle, multi-client reuse | `tests/server/Networking/ServerHandshake.spec.luau` |
| Startup preparation, rollback, failure observability | `tests/server/Server/Init.Networking.spec.luau` |
| Client ordering, one attempt, timeouts and cleanup | `tests/client/Client.Init.Handshake.spec.luau`, `Client.Init.Failures.spec.luau` |
| Real protocol modules bridged across isolated clients | `tests/client/Client.Init.Integration.spec.luau` |

The client fixture supplies a controlled clock, timeout callback and transport.
Tests resume initialization in a coroutine and deliver protocol messages
explicitly, including immediate responses during sends. Two cloned client
modules provide separate one-attempt state while sharing protocol modules.

## Validation and remaining engine checks

Run `npm run test:unit` during implementation and `npm test` for final validation.
Do not skip the new specs or lower coverage thresholds to hide the red phase.

Before considering N2 implemented, also exercise a real server and two Studio
clients: transport discovery while instances replicate, RemoteEvent delivery,
actual PlayerRemoving wiring, and reliable ACK-before-publication ordering.
The unit fixtures prove protocol behavior and use real Roblox transport
Instances, but do not emulate engine network delivery. Caller-owned buffer tests
prove direct-write composition; they do not measure allocator activity or CPU
performance. Consumer documentation from the story is a later implementation
deliverable, outside this boilerplate-and-tests pass.
