---
title: ActorViews API
---

# ActorViews API

Client lookup and read surfaces are frozen facades. There are no public installation, mutation or event-firing methods.

## ActorViewRegistry

| Signature | Return |
| --- | --- |
| `KRF.ActorViewRegistry.GetActorViewById(actorId: string) -> ActorView?` | Registered client identity, or `nil`; check `IsAvailable()` before targeting |
| `KRF.ActorViewRegistry.GetActorViewByModel(model: Model) -> ActorView?` | Current Model association, or `nil` |
| `KRF.ActorViewRegistry.GetAllActorViews() -> { ActorView }` | Fresh array of registered client identities, including any retained unavailable views; no enumeration order guarantee |

| Event | Boundary |
| --- | --- |
| `OnActorViewAdded: Event<ActorView>` | Initial baseline and registry indexes are installed; read current state in the callback |
| `OnActorViewRemoving: Event<ActorView>` | Retirement announced before registry removal and view destruction; a previously live view can still report available |

Normal removal does not fire `view.OnUnavailable`. A terminal stream fault can instead retain the indexed view, clear its domains and fire OnUnavailable without removing it. Own cleanup per exact view object and handle both paths. Registry enumeration is a snapshot; editing its returned array does not change the registry.

## ActorView

| Signature | Return |
| --- | --- |
| `view:GetId() -> string` | Actor identity |
| `view:GetModel() -> Model?` | Current local Model, which can be absent |
| `view:IsAvailable() -> boolean` | Whether this view is still available |
| `view:GetDomain(id: string) -> DomainView?` | Visible domain or `nil` |
| `view:GetDomainIds() -> { string }` | Frozen, sorted domain IDs |
| `view:GetTags() -> TagsView` | Always-present typed Tag surface |
| `view:GetResources() -> ResourcesView` | Always-present typed Resource surface |
| `view:GetActions() -> ActionsView` | Always-present typed Action surface |

| Event | Payload |
| --- | --- |
| `OnModelChanged` | `(previous: Model?, current: Model?)` |
| `OnDomainsChanged` | `{ added: { string }, removed: { string } }`; frozen arrays sorted by domain ID, after membership installation |
| `OnUnavailable` | No arguments; terminal unavailability is installed and domains are empty |

After destruction, GetModel and GetDomain return nil, domain IDs are empty, and IsAvailable returns false. GetId retains the original identity. Typed convenience views remain read-only objects but return absent state. An unavailable or destroyed reference cannot become a current target again.

## TagsView

```lua
local tags: KRF.TagsView = view:GetTags()
```

| Signature | Return |
| --- | --- |
| `tags:HasTag(tagId: string) -> boolean` | Visible active presence |
| `tags:GetTag(tagId: string) -> ActiveTagSnapshot?` | Frozen snapshot, or `nil` |
| `tags:GetActiveTags() -> { ActiveTagSnapshot }` | Frozen snapshots sorted by Tag ID |

`ActiveTagSnapshot` contains `tagId: string`, `stackCount: number` and `remainingDuration: number?`. Duration estimates the aggregate timed deadline at query time; nil means no timed deadline. Mixed timed and indefinite stacks retain the longest finite deadline until timed instances disappear. An estimate reaching zero does not remove the Tag locally.

`OnTagAdded`, `OnTagRemoved`, `OnTagRefreshed` and `OnTagExpired` each carry a Tag ID string. `OnStateChanged` carries `"Commit" | "Baseline"` when the installed aggregate state changes, not for every semantic occurrence. Baselines update current state without replaying additions or refreshes. Server-only Tags always appear absent.

## ResourcesView

The complete method, snapshot and event contracts are in [Resources API](../resources/api#resources-view). `GetResource` and `GetCurrent` include locally estimated regeneration. `OnResourceChanged` reports installed server updates, not each estimate change.

## ActionsView

```lua
local actions: KRF.ActionsView = view:GetActions()
```

| Signature | Return |
| --- | --- |
| `actions:IsActionActive(actionId: string) -> boolean` | Whether a visible activation exists |
| `actions:GetAction(sequenceId: number) -> ActionSnapshot?` | Visible activation, or `nil` |
| `actions:GetActiveActions() -> { ActionSnapshot }` | Frozen snapshots ordered by sequence ID |

`ActionSnapshot` contains only `actionId: string` and `sequenceId: number`. It doesn't expose callback state, parameters, held locks, grants or a general Action phase model.

`OnActionStarted`, `OnActionEnded` and `OnActionInterrupted` each carry an ActionSnapshot. The interrupted snapshot does not include a server interruption reason. `OnStateChanged` carries `"Commit" | "Baseline"` when installed active state changes. A baseline does not replay lifecycle history.

Lifecycle events describe occurrences, while queries read installed state. A Started notification does not promise the activation will still be running when a consumer later queries it. Several activations of the same Action ID can coexist; sequence IDs distinguish them.

For a local request's accepted sequence ID or rejection reason, use [ClientActionRuntime.OnActionRequest](../actions/client-api#request-observations). A server-only Action can be accepted without ever appearing in this view.

## DomainView

See [Replication API](../replication/api#domainview) for `GetState`, `GetEvent` and `OnChanged`.
