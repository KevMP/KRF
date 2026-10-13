# Replication Domain Registry

`ReplicationDomainRegistry` exposes the immutable domain catalog published by `Server.Init`.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ReplicationDomainRegistry = require(KRF.server.Replication.ReplicationDomainRegistry)
```

Returned type shapes are in [Replication Types](./replication-types#loaded-replication-domain-definition). Before publication, `Get` returns `nil` and collection reads return empty frozen tables. Registration is owned by startup; this read API has no runtime registration method.

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

Returns the frozen compiled domain definition, or `nil` for an unknown id.

### `GetAll() -> {LoadedReplicationDomainDefinition}` {#get-all}

Returns the frozen complete domain array in catalog order.

### `GetAllById() -> {[string]: LoadedReplicationDomainDefinition}` {#get-all-by-id}

Returns the frozen id-indexed catalog.

## Related

- [Replication domains guide](/Networking/replication-domains)
- [Replication Types](./replication-types)
- [Server API](/api/Server/)
- [Schema API](./schema)
