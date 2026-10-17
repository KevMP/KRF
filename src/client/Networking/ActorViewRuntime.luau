--!strict
local Types = require(script.Parent.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local Registry = require(script.Parent.Parent.Actor.ActorViewRegistry)

local ActorViewRuntime = {}

-- Deliberately inert N5 skeleton. N4 can deliver every callback without a missing
-- member/require failure. Tests assert the publication and recovery still missing.
function ActorViewRuntime.new(
	_protocol: SharedNetworkingTypes.ClientProtocol,
	_schemas: SharedNetworkingTypes.ActorSchemaCatalog,
	_options: Types.ActorViewOptions
): Types.ActorViewRuntime
	return {
		registry = Registry,
		consumer = {
			OnBaselineReady = function(
				_actor: Types.ActorStreamRecord,
				_revision: number,
				_domains: { [string]: SharedNetworkingTypes.ActorDomainTruth }
			): ()
			end,
			OnCommitReady = function(
				_actor: Types.ActorStreamRecord,
				_revision: number,
				_patches: { SharedNetworkingTypes.ActorDomainPatch },
				_events: { SharedNetworkingTypes.ActorEvent }
			): ()
			end,
			OnActorHalted = function(_actor: Types.ActorStreamRecord): () end,
			OnActorRemoved = function(_actor: Types.ActorStreamRecord): () end,
			OnModelBound = function(_actor: Types.ActorStreamRecord, _model: Model): () end,
			OnModelUnbound = function(_actor: Types.ActorStreamRecord, _model: Model): () end,
		},
		_InspectForTests = function(_self: Types.ActorViewRuntime, _handle: number): Types.ActorViewDiagnostics?
			return nil
		end,
		Destroy = function(_self: Types.ActorViewRuntime): () end,
	}
end

return ActorViewRuntime
