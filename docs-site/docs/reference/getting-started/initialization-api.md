---
title: Initialization API
---

# Initialization API

## Server.Init

```lua
KRF.Server.Init(config: KRF.ServerStartConfig) -> (boolean, KRF.ServerStartupFailure?)
```

Loads startup definitions and publishes the server protocol. Returns `true, nil` on success, or `false, { system: string, reason: string }`. Check the result before registering Actors.

| Configuration field | Type | If omitted |
| --- | --- | --- |
| `properties` | `{ KRF.PropertyDefinition }` | Only built-in Properties |
| `tags` | `{ KRF.TagDefinition }` | Empty catalog |
| `resources` | `{ KRF.ResourceDefinition }` | Empty catalog |
| `actions` | `{ KRF.ActionFactory }` | Empty catalog |
| `controllers` | `{ KRF.ControllerDefinition }` | Only framework controllers |
| `replicationDomains` | `{ KRF.ReplicationDomainDefinition }` | Only applicable built-in domains |
| `commands` | `{ KRF.CommandDefinition }` | No game-defined Commands |
| `hints` | `{ KRF.HintDefinition }` | No Hints |
| `actionRequestSchemas` | `KRF.ActionRequestSchemas` | No client Action request declarations |
| `actionControlAuthority` | `(player: Player, actor: KRF.Actor) -> boolean` | Character ownership only |

`actionControlAuthority` is a server-only, synchronous authorization callback for delegated Action control. KRF consults it when the player doesn't own the Actor. Only an exact `true` allows access; errors and yields deny it. Control is checked again before Start commits. Stop and Interrupt follow the original connection receipt. Selecting an Actor on a client never supplies permission.

### Failure behavior

Startup returns the first failure with its system name. Examples include `Server`, `Property`, `Tag`, `Resource`, `Action`, `ActionRequest`, `Controller`, `ReplicationDomain`, `Command`, `Hint` and `Networking`. The corresponding API pages describe definition failures. A failed publication rolls back loaded catalogs and Networking.

| Server failure | Cause |
| --- | --- |
| `ServerInitAlreadyAttempted` | Init was already called in this server session, successfully or otherwise |
| `CatalogAlreadyLoaded` | A registry was loaded outside this startup transaction |
| `StartupInternalFailure:<detail>` | A protected startup operation raised an error; the reported system identifies the stage |

Successful Init does not register any Actors. Controller construction, attach-set dependency validation and domain snapshots occur during registration. Automatic Resource assignment can warn and leave a Resource absent without rejecting the Actor; read [Actor registration](../actors/guide) and [Resource assignment](../resources/guide#assign-it-to-an-actor) for those contracts.

Restart after a failed production startup. Test reset hooks are not a production lifecycle API.

## Client.Init

```lua
KRF.Client.Init(config: KRF.ClientInitConfig?) -> (boolean, KRF.ClientStartupFailure?)
```

Discovers server transport, reconstructs its schema metadata, installs client consumers and completes the readiness handshake. This call can yield while waiting for startup. Returns `true, nil` or `false, { system: string, reason: string }`.

| Configuration field | Type | If omitted |
| --- | --- | --- |
| `actionRequestSchemas` | `KRF.ActionRequestSchemas` | No client Action requests |
| `actionInputPolicies` | `KRF.ActionInputPolicies` | Default policy for each declared Action, where permitted |
| `actionPredictionPolicies` | `KRF.ActionPredictionPolicies` | No local [Presentation prediction](../presentation/api#actionpredictionpolicy) |
| `presentations` | `{ KRF.PresentationDefinition }` | No Presentation instances |

Configuration is validated before transport discovery. Unknown config fields are rejected. Invalid client policies fail under `ActionInput`; a release-required Action needs an explicit `WhileDown` policy.

| Failure / system | Cause |
| --- | --- |
| `ClientInitAlreadyAttempted` / `Client` | Init was already called, successfully or otherwise |
| `ClientConfigInvalid`, `ClientConfigFieldUnknown` / `Client` | Invalid config table or unknown field |
| `ActionRequestCommandsUnavailable`, `ActionRequestCommandsIncompatible` / `ActionRequest` | Server lacks the required outer Action Command contracts |
| `PresentationCatalogInvalid`, `PresentationDefinitionInvalid`, `PresentationDefinitionFieldUnknown`, `PresentationIdInvalid`, `PresentationIdDuplicate`, `PresentationCreateInvalid`, `PresentationEntryInvalid`, `PresentationEntryFieldUnknown`, `PresentationEntryEventInvalid`, `PresentationEntryStateInvalid`, `PresentationEntryAmbiguous`, `PresentationEntryIdInvalid` / `Presentation` | Invalid [Presentation catalog](../presentation/api#startup-failures) |
| `PresentationInstallationFailed` / `Presentation` | Presentation could not attach its source listeners during startup |
| `TransportUnavailable`, `HandshakeTimeout` / `Networking` | Discovery or readiness could not finish |
| `ProtocolMismatch`, `UnsupportedSchema`, `BootstrapTooLarge`, `MalformedBootstrap`, `ReadyRejected` / `Networking` | Invalid or incompatible server handshake |
| `InternalConsumerInitializationFailed`, `StartupInternalFailure:<detail>` / `Networking` | Consumer installation or another protected startup operation failed |

Action request schemas and input policies also propagate their own [validation reasons](../actions/client-api#startup-contract-failures). Matching the outer Commands does not prove that individual Action parameter schemas agree; Start checks the per-Action contract tag.

After success, mutating runtime APIs may still return `ClientNotReady` if the client runtime is unavailable or has been torn down. Queries can return `nil` or empty results according to their own contracts. No public startup event replaces the return value.

See [Initialization](./initialization), [Action request contracts](../actions/requests) and [Client action API](../actions/client-api).
