--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: (string, () -> ()) -> () = (JestGlobals.it :: unknown) :: (string, () -> ()) -> ()
local expect = JestGlobals.expect
local InputPlans = require(KRF.client.Input.utils.InputPreparedStore)
local ActionPlans = require(KRF.client.Action.utils.ActionPreparedPlans)

it("cannot release or consume a legitimate prepared input capability through a forged key", function()
	local store: InputPlans.Store = InputPlans.new()

	local plan = assert(
		store.Put({ generation = 1, validators = 0, kind = "Epoch", profiles = nil, consumed = false }),
		"Expected capability"
	)

	expect(store.Read(false)).toBeNil()
	store.Release(false)
	store.Release({})
	expect(store.Read(plan) ~= nil).toBe(true)
	store.Release(plan)
	expect(store.Read(plan)).toBeNil()
	store.Clear()
end)

it("rejects non-table Action capabilities without consuming another plan or losing disposal", function()
	local disposed: { string } = {}

	local store: ActionPlans.Store<string> = ActionPlans.new(function(record: string): ()
		table.insert(disposed, record)
	end)

	local token = assert(store.Create("Original"), "Expected capability")
	expect(store.Read(1)).toBeNil()
	expect({ store.Take(false) }).toEqual({ nil, false })
	expect(store.Read(token)).toBe("Original")
	store.Clear()
	expect(disposed).toEqual({ "Original" })
	expect({ store.Take(token) }).toEqual({ nil, true })
end)
