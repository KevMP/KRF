--!strict
-- Benchmark-local wrappers. Every wrapper delegates once to the original function.
-- Inclusive categories overlap; raw samples permit analysis without adding them.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Capture = require(KRF.server.Networking.utils.PublicationCapture)
local Validator = require(KRF.shared.Networking.utils.SchemaValidator)
local Compiler = require(KRF.shared.Networking.CodecCompiler)
local Wire = require(KRF.shared.Networking.ActorStreamCodec)
local Awareness = require(KRF.server.Networking.ActorAwarenessRuntime)
local Publication = require(KRF.server.Networking.PublicationRuntime)
local Tags = require(KRF.server.Networking.utils.TagsReplication)
local TagController = require(KRF.server.Tags.TagController)
local TagTypes = require(KRF.server.Tags.types)
local Scheduler = require(KRF.server.Networking.utils.PublicationScheduler)

local Probe = {}
local enabled = false
local captureDepth = 0
local samples: { [string]: { totalUs: number, calls: number } } = {}
local restores: { () -> () } = {}

local function wrap(name: string, callback: (...any) -> ...any): (...any) -> ...any
	return function(...: any): ...any
		if not enabled then
			return callback(...)
		end

		local started = os.clock()
		local first, second, third = callback(...)
		local elapsed = (os.clock() - started) * 1e6
		local values = samples[name]

		if values == nil then
			values = { totalUs = 0, calls = 0 }
			samples[name] = values
		end

		values.totalUs += elapsed
		values.calls += 1

		return first, second, third
	end
end

local function patch(owner: any, key: string, value: any): ()
	local original = owner[key]

	owner[key] = value

	table.insert(restores, function()
		owner[key] = original
	end)
end

function Probe.domain(definition: any, observerName: string?): any
	definition.snapshot = wrap("snapshotUs", definition.snapshot)

	local observe: ((...any) -> ...any)? = definition.observe

	if observe ~= nil then
		definition.observe = function(actor: any, committed: any): any
			return observe(actor, wrap(observerName or "n3ObserverUs", committed))
		end
	end

	return definition
end

function Probe.install(): ()
	local compileCapture = Capture.Compile

	patch(Capture, "Compile", function(schema: any): any
		local plan = compileCapture(schema)

		local capture = wrap("captureInclusiveUs", function(value: any, previous: any): ...any
			captureDepth += 1
			local result, reason = plan:Capture(value, previous)
			captureDepth -= 1

			return result, reason
		end)

		return {
			Capture = function(_plan: any, value: any, previous: any): ...any
				return capture(value, previous)
			end,
		}
	end)

	patch(Validator, "Validate", wrap("validationUs", Validator.Validate))
	local compile = Compiler.Compile

	patch(Compiler, "Compile", function(schema: any): ...any
		local codec, reason = compile(schema)

		if codec == nil then
			return nil, reason
		end

		local n3Measure = wrap("n3EncodedSizeUs", codec.Measure)
		local n4Measure = wrap("n4SchemaMeasureUs", codec.Measure)

		return {
			fixedSizeBytes = codec.fixedSizeBytes,
			maxSizeBytes = codec.maxSizeBytes,
			Write = codec.Write,
			Read = codec.Read,
			Measure = function(value: any): ...any
				return (if captureDepth > 0 then n3Measure else n4Measure)(value)
			end,
		},
			reason
	end)

	local compileWire = Wire.Compile

	patch(Wire, "Compile", function(...: any): any
		local codec: any = compileWire(...)

		local copy = table.clone(codec)
		copy.Measure = wrap("wireMeasureUs", codec.Measure)
		copy.Encode = wrap("wireEncodeUs", codec.Encode)

		return copy
	end)

	patch(Awareness, "Step", wrap("n4StepUs", Awareness.Step))
	patch(Scheduler, "Enqueue", wrap("schedulerEnqueueUs", Scheduler.Enqueue))
	patch(Scheduler, "DrainBudgeted", wrap("schedulerDrainUs", Scheduler.DrainBudgeted))
	local newController = TagController.new

	patch(TagController, "new", function(...: any): any
		local controller = newController(...) :: TagTypes.InternalTagController
		local observe = controller._observeMutations

		controller._observeMutations = function(
			receiver: TagTypes.InternalTagController,
			observer: TagTypes.TagMutationObserver
		): () -> ()
			local wrapped = table.clone(observer)
			wrapped.Commit = wrap("tagProjectionInclusiveUs", observer.Commit)

			return observe(receiver, wrapped)
		end

		return controller
	end)

	local newAwareness = Awareness.new

	patch(Awareness, "new", function(publication: any, ...: any): any
		-- Only wrap the observer installed by ActorAwarenessRuntime. Fixture observers are excluded.
		local observe = publication.ObserveCommits

		publication.ObserveCommits = function(receiver: any, callback: any): any
			return observe(receiver, wrap("n4CommitUs", callback))
		end

		local runtime = newAwareness(publication, ...)

		publication.ObserveCommits = observe

		return runtime
	end)

	patch(Publication, "WithActorCommit", wrap("commitInclusiveUs", Publication.WithActorCommit))
	local build = Tags.Build

	patch(Tags, "Build", function(...: any): any
		local definition = build(...)

		return if definition ~= nil then Probe.domain(definition, "tagN3ObserverUs") else nil
	end)
end

function Probe.start(): ()
	samples = {}
	enabled = true
end

function Probe.stop(): { [string]: { totalUs: number, calls: number } }
	enabled = false

	return samples
end

function Probe.restore(): ()
	enabled = false

	for index = #restores, 1, -1 do
		restores[index]()
	end

	table.clear(restores)
end

return Probe
