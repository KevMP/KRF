---
title: Controllers API
---

# Controllers API

## ControllerDefinition

| Field | Type | Contract |
| --- | --- | --- |
| `key` | `string` | Unique non-empty attachment key |
| `factory` | `(actor: Actor) -> Controller` | Creates a fresh object for this Actor |
| `dependsOn` | `{ string }?` | Dependencies that must be constructed first; defaults to empty |
| `autoAttach` | `boolean?` | Defaults to `true` |

The returned `KRF.Controller` must have `Destroy(self) -> ()`. Additional methods and state belong to your game. During registration, the factory receives the bound, not-yet-enabled Actor after its declared dependencies attach. Retrieve them with `actor:GetController(key)`.

Factories should return synchronously. ActorRuntime uses `pcall` to catch thrown factory errors; yielding suspends attachment rather than producing a non-yielding-callback rejection. Destroy uses the same error isolation: a thrown error is warned and cleanup continues, while a yield can suspend teardown. Normal teardown has no dependency-order guarantee.

KRF calls factories for each Actor, not during Controller catalog validation. Factories are responsible for cleanup if they fail before returning an object.

## ControllerRegistry

| Signature | Return |
| --- | --- |
| `KRF.ControllerRegistry.Get(key: string) -> ControllerDefinition?` | Frozen loaded definition or `nil` |
| `KRF.ControllerRegistry.GetKeys() -> { string }` | Fresh mutable list of registered keys in catalog order |
| `KRF.ControllerRegistry.GetAutoAttachKeys() -> { string }` | Fresh mutable list of automatic attachment keys in catalog order |
| `KRF.ControllerRegistry.ResolveOrder(keys: { string }) -> ({ string }?, string?)` | Dependency order for this exact set, or a reason |
| `KRF.ControllerRegistry.IsLoaded() -> boolean` | Whether definitions are installed |

Before catalog publication, Get returns nil, both key queries return empty lists and IsLoaded returns false. The lists are copies; changing them doesn't change the registry. Loaded definitions and their dependency lists are frozen copies of the authoring data. Callback references are retained.

`ResolveOrder` collapses repeated keys and uses catalog order for otherwise eligible definitions, regardless of the supplied key order. It returns a new list, including an empty list for an empty set, or nil/reason. Every required dependency must be in the supplied set.

| Ordering failure | Cause |
| --- | --- |
| `UnknownControllerKey:<key>` | A supplied key isn't registered |
| `DependencyNotInAttachSet:<key>-><dependency>` | A required dependency is outside the supplied set |
| `CyclicDependency` | No valid construction order exists |

## Startup validation

Author game Controllers through `Server.Init`. `ControllerRegistry.Load(definitions: {ControllerDefinition}) -> (boolean, string?)` is exported lifecycle infrastructure. It stages and validates the full catalog before publication, returning true/nil on success or false/reason on failure. Definitions cannot be reloaded during play.

Catalog validation checks dependencies across all definitions, including those with `autoAttach = false`. Actor attachment separately resolves the automatic set, so a dependency excluded from that set fails then with `DependencyNotInAttachSet`.

| Failure | Cause |
| --- | --- |
| `ControllerDefinitionsAlreadyLoaded` | Catalog already installed |
| `ControllerCatalogMustBeTable` | Invalid catalog container |
| `ControllerDefinitionMustBeTable` | Invalid entry |
| `ControllerKeyMissing`, `ControllerKeyMustBeString`, `ControllerKeyCannotBeEmpty` | Invalid key |
| `DuplicateControllerKey` | Repeated key |
| `ControllerFactoryMustBeFunction` | Invalid factory |
| `ControllerAutoAttachMustBeBoolean` | Invalid automatic attachment flag |
| `ControllerDependenciesMustBeTable`, `ControllerDependencyKeyInvalid` | Invalid dependency list |
| `MissingDependency:<key>-><dependency>` | Dependency doesn't exist in the catalog |
| `CyclicDependency` | Dependency cycle |

ActorRuntime reports factory and attachment failures separately; see [Actors API](../actors/api). Controller definitions have no public runtime events; Actor lifecycle events belong to ActorRuntime.

Server.Init supplies `TagController`, `PropertyController`, `ResourceController` and `ActionController` before the game catalog. Redefining one of those keys fails as a duplicate. The current Controller validator copies recognized fields and ignores extra fields; it does not promise strict unknown-field or dense-array rejection.
