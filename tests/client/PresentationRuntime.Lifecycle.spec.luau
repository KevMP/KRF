--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Presentation.types)
local Events = require(KRF.client.Presentation.PresentationEvents)
local Client = require(KRF.client)
local GoodSignal: any = require(KRF.shared.Signal.GoodSignal)
local HintState = require(KRF.client.Networking.utils.HintRuntimeState)
local ClientUtils = require(script.Parent.Utils.ClientTestUtils)

local fireEnvironment: any = getfenv(GoodSignal.Fire)

afterEach(function()
	setfenv(GoodSignal.Fire, fireEnvironment)
	Client._ResetForTests()
end)

local function ready(definitions: { Types.PresentationDefinition }): ()
	local fixture: ClientUtils.Fixture = ClientUtils.new()
	ClientUtils.start(fixture, { presentations = definitions })
	ClientUtils.bootstrap(fixture)
	ClientUtils.acknowledge(fixture)
	expect(fixture.result).toEqual({ success = true })
end

it("owns source selectors and creates one independent context per matching definition and receipt", function()
	local contexts: { Types.PresentationContext } = {}

	local function create(context: Types.PresentationContext): ()
		table.insert(contexts, context)
	end

	local binding = { event = Events.Hint.Received, id = "Impact" }
	local definition = { id = "First", entry = binding, create = create }
	ready({ definition, { id = "Second", entry = binding, create = create } })
	binding.id = "Changed"

	definition.create = function(_context: Types.PresentationContext): ()
		error("Unexpected mutated constructor")
	end

	HintState.Notify({ hintId = "Changed" })
	HintState.Notify({ hintId = "Impact", payload = 7 })
	HintState.Notify({ hintId = "Impact", payload = 8 })
	expect(#contexts).toBe(0)
	task.wait()
	expect(#contexts).toBe(4)
	expect(contexts[1]).never.toBe(contexts[2])
	expect(contexts[1].actor).toBeNil()
	local payloads: { number } = {}

	for _, context in contexts do
		local entry: Types.PresentationEntry = context.entry
		assert(entry.source == "Hint", "Expected Hint entry")
		expect(entry.hintId).toBe("Impact")
		expect(table.isfrozen(entry)).toBe(true)
		expect(table.isfrozen(context)).toBe(true)
		table.insert(payloads, entry.payload)
	end

	table.sort(payloads)
	expect(payloads).toEqual({ 7, 7, 8, 8 })
	contexts[1]:Finish()
	expect(contexts[1]:IsActive()).toBe(false)
	expect(contexts[2]:IsActive()).toBe(true)
end)

it("retires before cleanup, runs LIFO after failure and cancels yielding cleanup", function()
	local history: { string } = {}
	local context: Types.PresentationContext? = nil

	ready({
		{
			id = "Impact.Cleanup",
			entry = { event = Events.Hint.Received, id = "Impact" },
			create = function(current: Types.PresentationContext)
				context = current

				current:Own(function()
					table.insert(history, "oldest")
				end)

				current:Own(function()
					table.insert(history, "yielded")
					task.wait()
					table.insert(history, "unexpected continuation")
				end)

				current:Own(function()
					assert(not current:IsActive(), "Cleanup ran before instance retirement")
					current:Finish()

					current:Own(function()
						table.insert(history, "late")
					end)

					error("Expected cleanup failure")
				end)

				error("Expected create failure")
			end,
		},
	})

	HintState.Notify({ hintId = "Impact" })
	task.wait()
	task.wait()
	expect(history).toEqual({ "late", "yielded", "oldest" })
	assert(context ~= nil, "Expected constructed instance")
	expect(context:IsActive()).toBe(false)
	expect(Client._IsInitialized()).toBe(true)
end)

it("marks suspended instances inactive and discards queued constructors on reset", function()
	local suspended: Types.PresentationContext? = nil
	local trace: { string } = {}

	ready({
		{
			id = "Impact.Suspended",
			entry = { event = Events.Hint.Received, id = "Impact" },
			create = function(context: Types.PresentationContext)
				suspended = context
				task.wait(0.05)
				assert(not context:IsActive(), "Reset did not retire suspended instance")

				context:Own(function()
					table.insert(trace, "late cleanup")
				end)
			end,
		},
		{
			id = "Impact.Queued",
			entry = { event = Events.Hint.Received, id = "Queued" },
			create = function()
				table.insert(trace, "unexpected constructor")
			end,
		},
	})

	HintState.Notify({ hintId = "Impact" })
	task.wait()
	assert(suspended ~= nil, "Expected suspended constructor")
	HintState.Notify({ hintId = "Queued" })
	Client._ResetForTests()
	expect(suspended:IsActive()).toBe(false)
	task.wait(0.1)
	expect(trace).toEqual({ "late cleanup" })
end)

it("refuses overflow without evicting active occurrences and reuses a retired slot", function()
	local active: { Types.PresentationContext } = {}

	ready({
		{
			id = "Impact.Budget",
			entry = { event = Events.Hint.Received, id = "Impact" },
			create = function(context: Types.PresentationContext)
				table.insert(active, context)
			end,
		},
	})

	for _ = 1, 257 do
		HintState.Notify({ hintId = "Impact" })
	end

	task.wait()
	expect(#active).toBe(256)
	expect(active[1]:IsActive()).toBe(true)
	active[1]:Finish()
	HintState.Notify({ hintId = "Impact" })
	task.wait()
	expect(#active).toBe(257)
	expect(active[2]:IsActive()).toBe(true)
end)

it("contains a non-string constructor failure without terminating the next instance", function()
	local occurrences: number = 0
	local active: Types.PresentationContext? = nil
	local failed: Types.PresentationContext? = nil

	ready({
		{
			id = "Impact.Isolation",
			entry = { event = Events.Hint.Received, id = "Impact" },
			create = function(context: Types.PresentationContext)
				occurrences += 1

				if occurrences == 1 then
					failed = context
					error({}, 0)
				end

				active = context
			end,
		},
	})

	HintState.Notify({ hintId = "Impact" })
	HintState.Notify({ hintId = "Impact" })
	task.wait()
	assert(failed ~= nil and active ~= nil, "Both occurrences should run")
	expect(failed:IsActive()).toBe(false)
	expect(active:IsActive()).toBe(true)
end)

it("ignores a queued source callback from a retired installation after a new startup", function()
	local contexts: { Types.PresentationContext } = {}

	local definitions: { Types.PresentationDefinition } = {
		{
			id = "Impact.Generation",
			entry = { event = Events.Hint.Received, id = "Impact" },
			create = function(context: Types.PresentationContext)
				table.insert(contexts, context)
			end,
		},
	}

	ready(definitions)

	local pending: { () -> () } = {}

	local taskAdapter = {
		spawn = function(_runner: thread, callback: (...any) -> (), ...: any)
			local arguments = table.pack(...)

			table.insert(pending, function()
				callback(table.unpack(arguments, 1, arguments.n))
			end)
		end,
	}

	setfenv(GoodSignal.Fire, setmetatable({ task = taskAdapter }, { __index = fireEnvironment }))
	HintState.Notify({ hintId = "Impact", payload = "Old" })
	setfenv(GoodSignal.Fire, fireEnvironment)
	expect(#pending).toBe(1)

	Client._ResetForTests()
	ready(definitions)
	pending[1]()
	HintState.Notify({ hintId = "Impact", payload = "New" })
	task.wait()
	expect(#contexts).toBe(1)
	local entry: Types.PresentationEntry = contexts[1].entry
	assert(entry.source == "Hint", "Expected current Hint receipt")
	expect(entry.payload).toBe("New")
end)
