--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Transport: SharedNetworkingTypes.Transport = require(KRF.shared.Networking.Transport)

local parent: Folder

beforeEach(function()
	parent = Instance.new("Folder")
end)
afterEach(function()
	parent:Destroy()
end)

it("owns exactly one Reliable RemoteEvent and one reserved UnreliableRemoteEvent", function()
	local owned: SharedNetworkingTypes.OwnedTransport?, reason: string? = Transport.Create(parent)
	expect(reason).toBeNil()
	assert(owned ~= nil, "Expected framework transport")
	expect(owned.root.Parent).toBe(parent)
	expect(owned.reliable.Parent).toBe(owned.root)
	expect(owned.unreliable.Parent).toBe(owned.root)
	expect(owned.reliable.ClassName).toBe("RemoteEvent")
	expect(owned.unreliable.ClassName).toBe("UnreliableRemoteEvent")
	expect(#owned.root:GetDescendants()).toBe(2)
	expect(#parent:GetChildren()).toBe(1)
	for _, descendant: Instance in parent:GetDescendants() do
		expect(descendant:IsA("RemoteFunction")).toBe(false)
	end
	local located: SharedNetworkingTypes.OwnedTransport?, locateReason: string? = Transport.Locate(parent)
	expect(locateReason).toBeNil()
	assert(located ~= nil, "Expected located transport")
	expect(located.reliable).toBe(owned.reliable)
	expect(located.unreliable).toBe(owned.unreliable)
end)

it("rejects repeated creation without duplicating or replacing an owned transport", function()
	local first: SharedNetworkingTypes.OwnedTransport?, firstReason: string? = Transport.Create(parent)
	expect(firstReason).toBeNil()
	assert(first ~= nil, "Expected first transport")
	local second: SharedNetworkingTypes.OwnedTransport?, reason: string? = Transport.Create(parent)
	expect(second).toBeNil()
	expect(reason).toBe("TransportConflict")
	expect(#parent:GetChildren()).toBe(1)
	expect(first.root.Parent).toBe(parent)
	expect(#first.root:GetChildren()).toBe(2)
end)

it("detects a reserved root collision without deleting consumer-owned instances", function()
	local collision: StringValue = Instance.new("StringValue")
	collision.Name = Transport.ROOT_NAME
	collision.Value = "consumer-owned"
	collision.Parent = parent
	local owned: SharedNetworkingTypes.OwnedTransport?, reason: string? = Transport.Create(parent)
	expect(owned).toBeNil()
	expect(reason).toBe("TransportConflict")
	expect(collision.Parent).toBe(parent)
	expect(collision.Value).toBe("consumer-owned")
	expect(#parent:GetChildren()).toBe(1)
end)

it("reports unavailable transport immediately at the non-yielding discovery primitive", function()
	local owned: SharedNetworkingTypes.OwnedTransport?, reason: string? = Transport.Locate(parent)
	expect(owned).toBeNil()
	expect(reason).toBe("TransportUnavailable")
	expect(#parent:GetChildren()).toBe(0)
end)

type HierarchyCase = { name: string, reliableClass: string?, unreliableClass: string?, duplicateReliable: boolean? }
local hierarchyCases: { HierarchyCase } = {
	{ name = "missing Reliable", unreliableClass = "UnreliableRemoteEvent" },
	{ name = "missing Unreliable", reliableClass = "RemoteEvent" },
	{ name = "Reliable Folder", reliableClass = "Folder", unreliableClass = "UnreliableRemoteEvent" },
	{ name = "Reliable RemoteFunction", reliableClass = "RemoteFunction", unreliableClass = "UnreliableRemoteEvent" },
	{ name = "Unreliable RemoteEvent", reliableClass = "RemoteEvent", unreliableClass = "RemoteEvent" },
	{
		name = "duplicate Reliable names",
		reliableClass = "RemoteEvent",
		unreliableClass = "UnreliableRemoteEvent",
		duplicateReliable = true,
	},
}
for _, testCase: HierarchyCase in hierarchyCases do
	it("rejects a hierarchy with " .. testCase.name .. " without repairing it from the client", function()
		local root: Folder = Instance.new("Folder")
		root.Name = Transport.ROOT_NAME
		root.Parent = parent
		if testCase.reliableClass ~= nil then
			local reliable: Instance = Instance.new(testCase.reliableClass)
			reliable.Name = Transport.RELIABLE_NAME
			reliable.Parent = root
		end
		if testCase.unreliableClass ~= nil then
			local unreliable: Instance = Instance.new(testCase.unreliableClass)
			unreliable.Name = Transport.UNRELIABLE_NAME
			unreliable.Parent = root
		end
		if testCase.duplicateReliable then
			local duplicate: RemoteEvent = Instance.new("RemoteEvent")
			duplicate.Name = Transport.RELIABLE_NAME
			duplicate.Parent = root
		end
		local originalCount: number = #root:GetChildren()
		local owned: SharedNetworkingTypes.OwnedTransport?, reason: string? = Transport.Locate(parent)
		expect(owned).toBeNil()
		expect(reason).toBe("InvalidTransport")
		expect(#root:GetChildren()).toBe(originalCount)
	end)
end

it("rejects duplicate root names instead of choosing an ambiguous transport", function()
	for _ = 1, 2 do
		local root: Folder = Instance.new("Folder")
		root.Name = Transport.ROOT_NAME
		root.Parent = parent
	end
	local owned: SharedNetworkingTypes.OwnedTransport?, reason: string? = Transport.Locate(parent)
	expect(owned).toBeNil()
	expect(reason).toBe("InvalidTransport")
end)

it("destroys only its owned hierarchy and treats repeated cleanup as a no-op", function()
	local unrelated: Folder = Instance.new("Folder")
	unrelated.Name = "GameData"
	unrelated.Parent = parent
	local owned: SharedNetworkingTypes.OwnedTransport?, reason: string? = Transport.Create(parent)
	expect(reason).toBeNil()
	assert(owned ~= nil, "Expected owned transport")
	owned.Destroy()
	owned.Destroy()
	expect(owned.root.Parent).toBeNil()
	expect(unrelated.Parent).toBe(parent)
	expect(#parent:GetChildren()).toBe(1)
end)

it("rejects a reserved root with the wrong class without modifying it", function()
	local root: StringValue = Instance.new("StringValue")
	root.Name = Transport.ROOT_NAME
	root.Value = "owned elsewhere"
	root.Parent = parent
	local owned: SharedNetworkingTypes.OwnedTransport?, reason: string? = Transport.Locate(parent)
	expect(owned).toBeNil()
	expect(reason).toBe("InvalidTransport")
	expect(root.Value).toBe("owned elsewhere")
end)

it("client-side transport view cleanup cannot destroy the server-owned hierarchy", function()
	local owner: SharedNetworkingTypes.OwnedTransport?, createReason: string? = Transport.Create(parent)
	expect(createReason).toBeNil()
	assert(owner ~= nil, "Expected owned transport")
	local view: SharedNetworkingTypes.OwnedTransport?, locateReason: string? = Transport.Locate(parent)
	expect(locateReason).toBeNil()
	assert(view ~= nil, "Expected a non-owning transport view")
	view.Destroy()
	view.Destroy()
	expect(owner.root.Parent).toBe(parent)
	expect(#owner.root:GetChildren()).toBe(2)
end)

it("surfaces a failed hierarchy publication instead of returning a partially owned transport", function()
	-- Supply discovery through a structural fixture, then let Roblox reject the
	-- native Parent assignment. This isolates publication failure from lookup.
	local invalidParent: any = {
		GetChildren = function(_self: any): { Instance }
			return {}
		end,
	}
	local completed: boolean = pcall(function()
		Transport.Create(invalidParent)
	end)
	expect(completed).toBe(false)
end)
