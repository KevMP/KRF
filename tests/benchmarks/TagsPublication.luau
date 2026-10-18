--!strict
-- Standalone Studio measurement, deliberately outside Jest/coverage timing.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local TagTypes = require(KRF.server.Tags.types)
local ServerTypes = require(KRF.server.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local SharedTypes = require(KRF.shared.Networking.types)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local TagController = require(KRF.server.Tags.TagController)
local TagRegistry: TagTypes.TagRegistry = require(KRF.server.Tags.TagRegistry)
local DomainRegistry: ReplicationTypes.InternalReplicationDomainRegistry =
	require(KRF.server.Replication.ReplicationDomainRegistry)
local Publication: ServerTypes.PublicationRuntimeModule = require(KRF.server.Networking.PublicationRuntime)
local Adapter = require(KRF.server.Networking.utils.TagsReplication)
local Validator: SharedTypes.SchemaValidator = require(KRF.shared.Networking.utils.SchemaValidator)
local CodecCompiler: SharedTypes.CodecCompiler = require(KRF.shared.Networking.CodecCompiler)

type Mode = "Controller" | "Projection" | "Publication"
type Distribution = { medianUs: number, p95Us: number, maxUs: number, meanUs: number }
local originalValidate = Validator.Validate
local originalCompile = CodecCompiler.Compile
local activeController: TagTypes.InternalTagController? = nil
local activeRuntime: ServerTypes.PublicationRuntime? = nil
local disconnect: (() -> ())? = nil
local samplesPerTrial: number = 200
local trials: number = 3
local warmup: number = 32

local function summarize(samples: { number }): Distribution
	table.sort(samples)
	local total: number = 0
	for _, value: number in samples do
		total += value
	end
	return {
		medianUs = samples[math.ceil(#samples / 2)],
		p95Us = samples[math.ceil(#samples * 0.95)],
		maxUs = samples[#samples],
		meanUs = total / #samples,
	}
end

local function clean(): ()
	Validator.Validate = originalValidate
	CodecCompiler.Compile = originalCompile
	if activeRuntime ~= nil then
		activeRuntime:Destroy()
		activeRuntime = nil
	end
	if disconnect ~= nil then
		disconnect()
		disconnect = nil
	end
	if activeController ~= nil then
		activeController:Destroy()
		activeController = nil
	end
	TagRegistry._resetForTests()
end

local function measure(count: number, mode: Mode): any
	local definitions: { TagTypes.TagDefinition } = {}
	for index: number = 1, count do
		local definition: TagTypes.TagDefinition = {
			id = string.format("Scale.Tag%04d", index),
			visibility = "ClientVisible",
			duplicateBehavior = "Refresh",
			defaultDuration = 60,
		}
		table.insert(definitions, definition)
	end
	local loaded: boolean, loadReason: string? = TagRegistry.Load(definitions)
	assert(loaded, loadReason)
	local actor: ActorTypes.Actor = ActorEntity.new()
	actor.enabled = true
	local controller: TagTypes.InternalTagController = TagController.new(actor) :: TagTypes.InternalTagController
	activeController = controller
	assert(actor:SetController("TagController", controller), "Expected benchmark controller installation")
	for _, definition: TagTypes.TagDefinition in definitions do
		local added: boolean, reason: string? = controller:AddTag(definition.id)
		assert(added, reason)
	end
	local definition: ReplicationTypes.ReplicationDomainDefinition? = Adapter.Build(definitions)
	assert(definition ~= nil, "Expected a visible Tags domain")
	local catalog: ReplicationTypes.PreparedReplicationDomainCatalog?, prepareReason: string? =
		DomainRegistry.Prepare({ definition })
	assert(catalog ~= nil, prepareReason)
	local lastCommit: ServerTypes.PublicationCommit? = nil
	local commitCount: number = 0
	if mode == "Projection" then
		definition.snapshot(actor)
		assert(definition.observe ~= nil, "Expected the synchronous mutation observer")
		disconnect = definition.observe(actor, function()
			commitCount += 1
		end)
	elseif mode == "Publication" then
		local runtime: ServerTypes.PublicationRuntime = Publication.new(catalog)
		activeRuntime = runtime
		local attached: boolean, reason: string? = runtime:AttachActor(actor)
		assert(attached, reason)
		runtime:ObserveCommits(function(commit: ServerTypes.PublicationCommit)
			lastCommit = commit
			commitCount += 1
		end)
	end
	local mutation: number = 0
	local function refresh(): ()
		mutation += 1
		local added: boolean, reason: string? = controller:AddTag("Scale.Tag0001", { duration = 60 + mutation % 2 })
		assert(added, reason)
	end
	for _ = 1, warmup do
		refresh()
	end
	local samples: { number } = {}
	local trialMedians: { number } = {}
	for _ = 1, trials do
		local trial: { number } = {}
		for index: number = 1, samplesPerTrial do
			local started: number = os.clock()
			refresh()
			local elapsed: number = (os.clock() - started) * 1000000
			table.insert(trial, elapsed)
			table.insert(samples, elapsed)
			if index % 20 == 0 then
				task.wait() -- Yield outside the measured interval; stepping is disabled.
			end
		end
		table.insert(trialMedians, summarize(trial).medianUs)
	end
	assert(#controller:GetActiveTags() == count, "Benchmark lost an active Tag")
	if mode ~= "Controller" then
		assert(commitCount == warmup + samplesPerTrial * trials, "Benchmark lost a mutation commit")
	end
	if mode == "Publication" then
		assert(
			lastCommit ~= nil and #lastCommit.patches == 1 and #lastCommit.events == 1,
			"Expected one patch and event"
		)
		local patch: ServerTypes.PublicationPatch = lastCommit.patches[1].patch
		assert(
			patch.kind == "Map" and patch.entries["Scale.Tag0001"] ~= nil and #patch.removed == 0,
			"Expected the refreshed entry alone"
		)
		local entries: number = 0
		for _ in patch.entries do
			entries += 1
		end
		assert(entries == 1, "One-Tag refresh emitted unrelated entries")
	end
	local result: any =
		{ activeVisibleIds = count, mode = mode, latency = summarize(samples), trialMedianUs = trialMedians }
	if mode == "Publication" then
		-- Separate untimed diagnostic pass. Wrappers delegate to the real N3
		-- validator/codec and are never installed during the latency samples.
		assert(activeRuntime ~= nil, "Expected the timed publication runtime")
		activeRuntime:Destroy()
		activeRuntime = nil
		local numericValidations: number = 0
		local enumValidations: number = 0
		local measuredEntries: number = 0
		local instanceQueries: number = 0
		Validator.Validate = function(schema: SharedTypes.CompiledSchema, value: any): (boolean, string?)
			if schema.kind == "U32" or schema.kind == "F64" then
				numericValidations += 1
			elseif schema.kind == "Enum" then
				enumValidations += 1
			end
			return originalValidate(schema, value)
		end
		CodecCompiler.Compile = function(schema: SharedTypes.CompiledSchema): (SharedTypes.CompiledCodec?, string?)
			local codec: SharedTypes.CompiledCodec?, reason: string? = originalCompile(schema)
			if codec == nil or schema.kind ~= "Map" then
				return codec, reason
			end
			local wrapped: SharedTypes.CompiledCodec = {
				fixedSizeBytes = codec.fixedSizeBytes,
				maxSizeBytes = codec.maxSizeBytes,
				Write = codec.Write,
				Read = codec.Read,
				Measure = function(value: any): (number?, string?)
					for _ in value do
						measuredEntries += 1
					end
					return codec.Measure(value)
				end,
			}
			return wrapped, reason
		end
		local originalInstances = controller.GetTagInstances
		controller.GetTagInstances = function(
			self: TagTypes.InternalTagController,
			id: string
		): { TagTypes.TagInstanceSnapshot }
			instanceQueries += 1
			return originalInstances(self, id)
		end
		local diagnostic: ServerTypes.PublicationRuntime = Publication.new(catalog)
		activeRuntime = diagnostic
		local attached: boolean, reason: string? = diagnostic:AttachActor(actor)
		assert(attached, reason)
		numericValidations, enumValidations, measuredEntries, instanceQueries = 0, 0, 0, 0
		refresh()
		result.work = {
			controllerInstanceQueries = instanceQueries,
			numericValidations = numericValidations,
			enumValidations = enumValidations,
			entriesPassedToFullMapMeasure = measuredEntries,
			patchEntries = 1,
		}
	end
	clean()
	return result
end

TagController._setAutomaticSteppingEnabledForTests(false)
local completed: boolean, failure: any = pcall(function()
	local rows: { any } = {}
	for _, count: number in { 1, 16, 64, 256, 1024, 4096 } do
		for _, mode: Mode in { "Controller", "Projection", "Publication" } do
			print("Measuring " .. mode .. " with " .. count .. " active visible Tag IDs")
			table.insert(rows, measure(count, mode))
		end
	end
	print("__KRF_TAGS_SCALING__ " .. HttpService:JSONEncode({
		samplesPerTrial = samplesPerTrial,
		trials = trials,
		warmup = warmup,
		rows = rows,
	}))
end)
clean()
TagController._setAutomaticSteppingEnabledForTests(true)
if not completed then
	error(failure, 0)
end
return nil
