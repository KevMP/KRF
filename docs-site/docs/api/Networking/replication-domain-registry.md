# Replication Domain Registry

`ReplicationDomainRegistry` exposes the immutable domain catalog published by `Server.Init`.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ReplicationDomainRegistry = require(KRF.server.Replication.ReplicationDomainRegistry)
```

Before publication, `Get` returns `nil` and collection reads return empty frozen tables. Registration is owned by startup; this read API has no runtime registration method. Author domains using the [domain definition contract](/Networking/replication-domains#domain-definition).

## Members

| Kind | Signature |
| --- | --- |
| Method | [`IsLoaded() -> boolean`](#is-loaded) |
| Method | [`Get(domainId: string) -> LoadedReplicationDomainDefinition?`](#get) |
| Method | [`GetAll() -> {LoadedReplicationDomainDefinition}`](#get-all) |
| Method | [`GetAllById() -> {[string]: LoadedReplicationDomainDefinition}`](#get-all-by-id) |

## Methods

### `IsLoaded() -> boolean` {#is-loaded}

Returns `true` after successful startup publication, including an empty catalog.

### `Get(domainId: string) -> LoadedReplicationDomainDefinition?` {#get}

Returns frozen domain metadata, or `nil` for an unknown id. Metadata includes `id`, the compiled `state` schema, an `events` array of ids and compiled payload schemas, the normalized `audience`, and the authored `snapshot` and optional `observe` callback references. Omitted events become an empty array; omitted audience becomes `All`. Nested metadata collections are frozen; compiled schema layout is private.

### `GetAll() -> {LoadedReplicationDomainDefinition}` {#get-all}

Returns the frozen complete domain array in catalog order.

### `GetAllById() -> {[string]: LoadedReplicationDomainDefinition}` {#get-all-by-id}

Returns the frozen id-indexed catalog.

## Related

- [Replication domains guide](/Networking/replication-domains)
- [Server API](/api/Server/)
- [Schema API](./schema)
