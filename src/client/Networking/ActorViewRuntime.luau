--!strict
local Types = require(script.Parent.ActorViewTypes)
local StreamTypes = require(script.Parent.ActorStreamTypes)
local WireTypes = require(script.Parent.Parent.Parent.shared.Networking.ActorStreamTypes)
local ProtocolTypes = require(script.Parent.Parent.Parent.shared.Networking.ProtocolTypes)
local Registry = require(script.Parent.Parent.Actor.ActorViewRegistry)

local ActorViewRuntime = {}

-- Deliberately inert N5 skeleton. N4 can deliver every callback without a missing
-- member/require failure. Tests assert the publication and recovery still missing.
function ActorViewRuntime.new(
	_protocol: ProtocolTypes.ClientProtocol,
	_schemas: WireTypes.SchemaCatalog,
	_options: Types.Options
): Types.Runtime
	return {
		registry = Registry,
		consumer = {
			OnBaselineReady = function(
				_actor: StreamTypes.ActorRecord,
				_revision: number,
				_domains: { [string]: WireTypes.DomainTruth }
			): ()
			end,
			OnCommitReady = function(
				_actor: StreamTypes.ActorRecord,
				_revision: number,
				_patches: { WireTypes.DomainPatch },
				_events: { WireTypes.Event }
			): ()
			end,
			OnActorHalted = function(_actor: StreamTypes.ActorRecord): () end,
			OnActorRemoved = function(_actor: StreamTypes.ActorRecord): () end,
			OnModelBound = function(_actor: StreamTypes.ActorRecord, _model: Model): () end,
			OnModelUnbound = function(_actor: StreamTypes.ActorRecord, _model: Model): () end,
		},
		_InspectForTests = function(_self: Types.Runtime, _handle: number): Types.Diagnostics?
			return nil
		end,
		Destroy = function(_self: Types.Runtime): () end,
	}
end

return ActorViewRuntime
