--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.server.ActionRequest.types)
local ActorTypes = require(KRF.server.Actor.types)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local ProtocolUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)
local Ledger: Types.ActionReceiptLedgerModule = require(KRF.server.ActionRequest.ActionReceiptLedger)

local instances: { Instance } = {}

afterEach(function()
	for _, instance: Instance in instances do
		instance:Destroy()
	end

	table.clear(instances)
end)

local function binding(actionId: string?): Types.ActionReceiptBinding
	local player: Player = ProtocolUtils.createPlayer()
	table.insert(instances, player)
	local actor: ActorTypes.Actor = ActorEntity.new()

	return {
		player = player,
		actor = actor,
		actionId = actionId or "Movement.Sprint",
		allowsStop = true,
		allowsInterrupt = true,
		onDisconnect = "Interrupt",
	}
end

local function reserve(
	ledger: Types.ActionReceiptLedger,
	connection: unknown,
	requestId: number
): Types.ActionReceiptBinding
	local owned: Types.ActionReceiptBinding = binding()
	local reserved: boolean, reason: string? = ledger:Reserve(connection, requestId, owned)
	expect(reason).toBeNil()
	expect(reserved).toBe(true)

	return owned
end

it("reserves a provisional receipt before any sequence id exists", function()
	local ledger: Types.ActionReceiptLedger = Ledger.new()
	local connection: {} = {}
	local owned: Types.ActionReceiptBinding = reserve(ledger, connection, 7)

	expect(ledger:Get(connection, 7)).toEqual({
		player = owned.player,
		actor = owned.actor,
		actionId = "Movement.Sprint",
		allowsStop = true,
		allowsInterrupt = true,
		onDisconnect = "Interrupt",
		requestId = 7,
		state = "Provisional",
		sequenceId = nil,
		stopDelivered = false,
	})

	expect(ledger:GetCount(connection)).toBe(1)
end)

it("activates a provisional receipt with the authoritative sequence id", function()
	local ledger: Types.ActionReceiptLedger = Ledger.new()
	local connection: {} = {}
	reserve(ledger, connection, 7)
	expect(ledger:Activate(connection, 7, 41)).toBe(true)

	local snapshot: Types.ActionReceiptSnapshot? = ledger:Get(connection, 7)
	assert(snapshot ~= nil, "Expected a live receipt")
	expect(snapshot.state).toBe("Live")
	expect(snapshot.sequenceId).toBe(41)
	expect(ledger:Activate(connection, 7, 42)).toBe(false)
	expect(ledger:Activate(connection, 8, 42)).toBe(false)
end)

it("scopes identical request ids to their exact connection generation", function()
	local ledger: Types.ActionReceiptLedger = Ledger.new()
	local original: {} = {}
	local reconnected: {} = {}
	reserve(ledger, original, 1)
	expect(ledger:Get(reconnected, 1)).toBeNil()
	reserve(ledger, reconnected, 1)
	expect(ledger:Activate(original, 1, 10)).toBe(true)

	local reconnectedSnapshot: Types.ActionReceiptSnapshot? = ledger:Get(reconnected, 1)
	assert(reconnectedSnapshot ~= nil, "Expected the reconnected receipt")
	expect(reconnectedSnapshot.state).toBe("Provisional")
end)

it("rejects a duplicate reservation without replacing the original binding", function()
	local ledger: Types.ActionReceiptLedger = Ledger.new()
	local connection: {} = {}
	local owned: Types.ActionReceiptBinding = reserve(ledger, connection, 3)
	local reserved: boolean, reason: string? = ledger:Reserve(connection, 3, binding("Combat.Fireball"))
	expect(reserved).toBe(false)
	expect(reason).toBe("ActionReceiptDuplicate")

	local snapshot: Types.ActionReceiptSnapshot? = ledger:Get(connection, 3)
	assert(snapshot ~= nil, "Expected the original receipt")
	expect(snapshot.actionId).toBe(owned.actionId)
end)

it("bounds receipts per connection without starving another connection", function()
	local ledger: Types.ActionReceiptLedger = Ledger.new({ maxConnectionReceipts = 2, maxGlobalReceipts = 8 })
	local first: {} = {}
	local second: {} = {}
	reserve(ledger, first, 1)
	reserve(ledger, first, 2)

	local reserved: boolean, reason: string? = ledger:Reserve(first, 3, binding())
	expect(reserved).toBe(false)
	expect(reason).toBe("ActionReceiptCapacityReached")
	reserve(ledger, second, 1)
	expect(ledger:GetCount(first)).toBe(2)
	expect(ledger:GetCount()).toBe(3)
end)

it("bounds receipts globally across connections", function()
	local ledger: Types.ActionReceiptLedger = Ledger.new({ maxConnectionReceipts = 8, maxGlobalReceipts = 2 })
	reserve(ledger, {}, 1)
	reserve(ledger, {}, 1)
	local reserved: boolean, reason: string? = ledger:Reserve({}, 1, binding())
	expect(reserved).toBe(false)
	expect(reason).toBe("ActionReceiptGlobalCapacityReached")
end)

it("releases capacity on retirement and treats repeated or unknown retirement as a no-op", function()
	local ledger: Types.ActionReceiptLedger = Ledger.new({ maxConnectionReceipts = 1, maxGlobalReceipts = 1 })
	local connection: {} = {}
	reserve(ledger, connection, 1)
	ledger:Retire(connection, 1)
	ledger:Retire(connection, 1)
	ledger:Retire(connection, 99)
	ledger:Retire({}, 1)
	expect(ledger:Get(connection, 1)).toBeNil()
	expect(ledger:GetCount()).toBe(0)
	reserve(ledger, connection, 2)
	expect(ledger:GetCount(connection)).toBe(1)
end)

it("reports Stop delivery only once and only for a live receipt", function()
	local ledger: Types.ActionReceiptLedger = Ledger.new()
	local connection: {} = {}
	reserve(ledger, connection, 5)
	expect(ledger:MarkStopDelivered(connection, 5)).toBe(false)
	expect(ledger:Activate(connection, 5, 12)).toBe(true)
	expect(ledger:MarkStopDelivered(connection, 5)).toBe(true)
	expect(ledger:MarkStopDelivered(connection, 5)).toBe(false)
	expect(ledger:MarkStopDelivered({}, 5)).toBe(false)

	local snapshot: Types.ActionReceiptSnapshot? = ledger:Get(connection, 5)
	assert(snapshot ~= nil, "A delivered Stop must leave the receipt live")
	expect(snapshot.state).toBe("Live")
	expect(snapshot.stopDelivered).toBe(true)
end)

it("returns frozen snapshots that do not change after later mutation", function()
	local ledger: Types.ActionReceiptLedger = Ledger.new()
	local connection: {} = {}
	reserve(ledger, connection, 9)
	local provisional: Types.ActionReceiptSnapshot? = ledger:Get(connection, 9)
	assert(provisional ~= nil, "Expected a provisional snapshot")
	expect(ledger:Activate(connection, 9, 3)).toBe(true)
	expect(table.isfrozen(provisional)).toBe(true)
	expect(provisional.state).toBe("Provisional")
	expect(provisional.sequenceId).toBeNil()
end)

it("closes one connection generation and returns its receipts in request order", function()
	local ledger: Types.ActionReceiptLedger = Ledger.new()
	local closing: {} = {}
	local unrelated: {} = {}
	reserve(ledger, closing, 4)
	reserve(ledger, closing, 2)
	reserve(ledger, unrelated, 3)
	expect(ledger:Activate(closing, 2, 20)).toBe(true)

	local removed: { Types.ActionReceiptSnapshot } = ledger:CloseConnection(closing)
	expect(#removed).toBe(2)
	expect(removed[1].requestId).toBe(2)
	expect(removed[1].state).toBe("Live")
	expect(removed[1].sequenceId).toBe(20)
	expect(removed[2].requestId).toBe(4)
	expect(removed[2].state).toBe("Provisional")
	expect(ledger:Get(closing, 2)).toBeNil()
	expect(ledger:GetCount(closing)).toBe(0)
	expect(ledger:GetCount(unrelated)).toBe(1)
	expect(ledger:CloseConnection(closing)).toEqual({})
end)

it("refuses new reservations after destruction and releases every receipt", function()
	local ledger: Types.ActionReceiptLedger = Ledger.new()
	local connection: {} = {}
	reserve(ledger, connection, 1)
	ledger:Destroy()
	ledger:Destroy()
	expect(ledger:GetCount()).toBe(0)
	expect(ledger:Get(connection, 1)).toBeNil()

	local reserved: boolean, reason: string? = ledger:Reserve(connection, 2, binding())
	expect(reserved).toBe(false)
	expect(reason).toBe("ActionReceiptLedgerDestroyed")
end)

for _, limits: Types.ActionReceiptLimits in
	{
		{ maxConnectionReceipts = -1 },
		{ maxConnectionReceipts = 1.5 },
		{ maxGlobalReceipts = math.huge },
		{ maxConnectionReceipts = 0 },
	} :: { Types.ActionReceiptLimits }
do
	it("rejects invalid receipt limits at construction", function()
		expect(function(): ()
			Ledger.new(limits)
		end).toThrow("InvalidActionReceiptLimit")
	end)
end
