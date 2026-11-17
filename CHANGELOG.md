# Changelog

## Unreleased

### Breaking: registered Properties

All Property IDs must be declared in `Server.Init({ properties = ... })`. Built-in `WalkSpeed` and `JumpPower` still load when the field is omitted. A registered Property need not be assigned to every Actor: use `autoAssign`, an Actor registration override, a base write, or a backing Resource to assign it.

Previously, `SetBaseProperty("Defense", 20)` could create any name. Declare `{ id = "Defense", defaultBaseValue = 0 }` before that write. Unknown IDs now return `false, "UnknownPropertyId"` without mutation or notifications.

Resource sources previously used `{ propertyName = "MaxStamina", defaultBaseValue = 100 }`. Move the default into a Property definition and change the source to `{ propertyName = "MaxStamina" }`. Resource `defaultBaseValue` is rejected. The Resource generator now accepts `--max MaxStamina`; the old `--max MaxStamina=100` syntax is rejected.

Tag modifier and Action cost multiplier IDs must also be registered. Startup validates all references against the prepared Property catalog before publishing any catalogs. Direct registry loads enforce the same prerequisite. Standalone `PropertyController.new` now requires a loaded PropertyRegistry.

Actor-specific values can be supplied as `ActorRuntime.RegisterActor(model, { properties = { MaxStamina = 150 } })`. They are validated before binding and installed silently before dependent controllers initialize. See the [complete Property, Resource and Tag example](docs-site/docs/documentation/Property/property-registry.md).
