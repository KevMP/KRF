--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.ActionRequest.types)
local Runtime = require(KRF.client.ActionRequest.ClientActionRequestRuntime)
local Utils = require(script.Parent.Utils.ActionRequestClientTestUtils)
local fixture: Utils.Fixture?

afterEach(function()
	Utils.destroy(fixture)
	fixture = nil
end)

it("derives opaque string keys from incarnation and admitted command ID without adding wire fields", function()
	local created: Utils.Fixture = Utils.new()
	fixture = created
	local admissions: { Types.ActionRequestAdmission } = {}

	created.runtime:ObserveAdmissions(function(fact: Types.ActionRequestAdmission): ()
		table.insert(admissions, fact)
	end)

	assert(created.runtime:Start(Utils.selection(created, "Movement.Sprint")))
	assert(created.runtime:Stop(1))
	expect(#admissions).toBe(2)
	expect(type(admissions[1].requestKey)).toBe("string")
	expect(type(admissions[2].requestKey)).toBe("string")
	expect(admissions[1].originalStartKey).toBe(admissions[1].requestKey)
	expect(admissions[2].originalStartKey).toBe(admissions[1].requestKey)
	expect(admissions[2].requestKey).never.toBe(admissions[1].requestKey)
	expect(created.port.sent[2].request).toEqual({ originalStartRequestId = 1, payload = "" })
	local previous: unknown = admissions[1].requestKey
	created.runtime:Destroy()
	created.port = Utils.port()
	created.runtime = Runtime.new(created.catalog, { commands = created.port.port, incarnation = 2 })
	assert(created.runtime:Start(Utils.selection(created, "Movement.Sprint")))
	expect(assert(created.runtime:GetOriginalStart(1)).requestKey).never.toBe(previous)
end)

for _, incarnation: number in { 0, -1, 1.5, 9007199254740992, math.huge } do
	it("rejects an invalid or exhausted local incarnation " .. tostring(incarnation), function()
		local created: Utils.Fixture = Utils.new()
		fixture = created
		local unexpected: Types.ClientActionRequestRuntime?

		local success: boolean = pcall(function(): ()
			unexpected = Runtime.new(created.catalog, { commands = created.port.port, incarnation = incarnation })
		end)

		if unexpected ~= nil then
			unexpected:Destroy()
		end

		expect(success).toBe(false)
	end)
end
