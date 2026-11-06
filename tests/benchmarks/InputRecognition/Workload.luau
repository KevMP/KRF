--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Packages.KRF.client.Input.types)

export type Measurement = {
	customCalls: number,
	customDispatchSeconds: number,
	faultCalls: number,
	faultDispatchSeconds: number,
}

local Workload = {}

-- These timings include native Scriptable dispatch and diagnostics. Consumer
-- callbacks are trusted Luau; this workload does not establish a CPU sandbox.
function Workload.Run(input: Types.InputRuntime, press: (string) -> ()): Measurement
	local customCalls: number = 0
	local definitions: { [string]: Types.RecognizerDefinition } = {}

	local definition: Types.RecognizerDefinition = {
		inputs = { "X" },
		maxWindowSeconds = 60,
		onEvent = function(ctx: Types.RecognizerContext): Types.CustomMatch?
			customCalls += 1
			local count: number = (ctx:GetState("count") :: number?) or 0
			assert(ctx:SetState("count", count + 1), "BenchmarkStateRejected")
			assert(ctx:ScheduleAfter(0.5), "BenchmarkDeadlineRejected")

			return nil
		end,
	}

	for index: number = 1, 128 do
		definitions[string.format("Scalar%03d", index)] = definition
	end

	assert(input.SetSource("Benchmark.Scalars", { recognizers = definitions }), "BenchmarkScalarInstallFailed")
	assert(customCalls == 0, "ValidationInvokedCustomCallback")
	local started: number = os.clock()

	for _ = 1, 32 do
		press("X")
	end

	local customDispatchSeconds: number = os.clock() - started
	assert(customCalls == 8192, "CustomBenchmarkLostCallbacks")
	assert(input.RemoveSource("Benchmark.Scalars"), "BenchmarkScalarCleanupFailed")
	assert(input.GetRecognizer("Scalar001") == nil, "BenchmarkScalarOwnerLeaked")
	local faultCalls: number = 0
	local faults: { [string]: Types.RecognizerDefinition } = {}

	local faulty: Types.RecognizerDefinition = {
		inputs = { "X" },
		maxWindowSeconds = 1,
		onEvent = function(): any
			faultCalls += 1

			return { metadata = { invalid = {} } }
		end,
	}

	for index: number = 1, 128 do
		faults[string.format("Fault%03d", index)] = faulty
	end

	assert(input.SetSource("Benchmark.Faults", { recognizers = faults }), "BenchmarkFaultInstallFailed")
	started = os.clock()
	press("X")
	local faultDispatchSeconds: number = os.clock() - started
	assert(faultCalls == 128, "CustomFaultIsolationFailed")
	press("X")
	assert(faultCalls == 128, "FaultedCallbacksRevived")

	for id in faults do
		assert(assert(input.GetRecognizer(id), "MissingFaultedRecognizer").faulted, "MissingFaultStatus")
	end

	assert(input.RemoveSource("Benchmark.Faults"), "BenchmarkFaultCleanupFailed")
	assert(input.GetRecognizer("Fault001") == nil, "BenchmarkFaultOwnerLeaked")

	return {
		customCalls = customCalls,
		customDispatchSeconds = customDispatchSeconds,
		faultCalls = faultCalls,
		faultDispatchSeconds = faultDispatchSeconds,
	}
end

return Workload
