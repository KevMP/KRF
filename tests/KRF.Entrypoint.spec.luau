--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: (string, () -> ()) -> () = JestGlobals.it :: any
local expect = JestGlobals.expect

local KRF = require(ReplicatedStorage.Packages.KRF)

local package: Instance = ReplicatedStorage.Packages.KRF

local MEMBER_PATHS: { [string]: { string } } = {
	Server = { "server" },
	Client = { "client" },
	Schema = { "shared", "Networking", "Schema" },
	Signal = { "shared", "Signal", "SignalModule" },
	OwnedSignals = { "shared", "Signal", "OwnedSignals" },
	ActorRuntime = { "server", "Actor", "ActorRuntime" },
	ActorRegistry = { "server", "Actor", "ActorRegistry" },
	ControllerRegistry = { "server", "Controller", "ControllerRegistry" },
	TagRegistry = { "server", "Tags", "TagRegistry" },
	ResourceRegistry = { "server", "Resource", "ResourceRegistry" },
	ActionRegistry = { "server", "Action", "ActionRegistry" },
	ReplicationDomainRegistry = { "server", "Replication", "ReplicationDomainRegistry" },
	CommandRegistry = { "server", "Networking", "CommandRegistry" },
	CommandAuthorization = { "server", "Networking", "CommandAuthorization" },
	HintRegistry = { "server", "Networking", "HintRegistry" },
	HintAuthorization = { "server", "Networking", "HintAuthorization" },
	ServerHintRuntime = { "server", "Networking", "HintRuntime" },
	ActorViewRegistry = { "client", "Actor", "ActorViewRegistry" },
	ClientActionRuntime = { "client", "Action", "ClientActionRuntime" },
	ClientControls = { "client", "Controls", "ClientControls" },
	InputRuntime = { "client", "Input", "InputRuntime" },
	CommandRuntime = { "client", "Networking", "CommandRuntime" },
	ClientHintRuntime = { "client", "Networking", "HintRuntime" },
}

local function findModule(path: { string }): ModuleScript
	local current: Instance = package

	for _, name: string in path do
		current = current:FindFirstChild(name) :: Instance
	end

	return current :: ModuleScript
end

it("returns the same module each public member names inside the package", function()
	for member: string, path: { string } in MEMBER_PATHS do
		local expected: any = require(findModule(path)) :: any

		expect((KRF :: any)[member]).toBe(expected)
	end
end)

it("rejects an unknown member with a stable error naming it", function()
	local success: boolean, errorMessage: any = pcall(function(): ()
		local _: any = (KRF :: any).ActorController
	end)

	expect(success).toBe(false)
	expect(tostring(errorMessage)).toContain("KRF has no public member 'ActorController'")
end)

it("rejects a non-string member key", function()
	local success: boolean, errorMessage: any = pcall(function(): ()
		local _: any = (KRF :: any)[1]
	end)

	expect(success).toBe(false)
	expect(tostring(errorMessage)).toContain("KRF has no public member '1'")
end)

it("keeps public members read-only after a rejected assignment", function()
	local original: any = KRF.ActorRuntime

	local success: boolean = pcall(function(): ()
		(KRF :: any).ActorRuntime = {}
	end)

	expect(success).toBe(false)
	expect(KRF.ActorRuntime).toBe(original)
	expect(table.isfrozen(KRF :: any)).toBe(true)
end)

it("rejects replacing its metatable or member lookup", function()
	local lookup: any = getmetatable(KRF :: any)

	local replacedMetatable: boolean = pcall(function(): ()
		setmetatable(KRF :: any, {})
	end)

	local replacedLookup: boolean = pcall(function(): ()
		lookup.__index = function(): any
			return nil
		end
	end)

	expect(replacedMetatable).toBe(false)
	expect(replacedLookup).toBe(false)
	expect(getmetatable(KRF :: any)).toBe(lookup)
	expect(KRF.ActorRuntime).toBe(require(ReplicatedStorage.Packages.KRF.server.Actor.ActorRuntime) :: any)
end)

it("types definitions authored through the root module", function()
	local tag: KRF.TagDefinition =
		{ id = "Status.Example", duplicateBehavior = "Refresh", visibility = "ClientVisible" }

	local resource: KRF.ResourceDefinition = {
		id = "Resource.Example",
		max = { value = 10 },
		visibility = "ClientVisible",
	}

	expect(tag.id).toBe("Status.Example")
	expect(resource.id).toBe("Resource.Example")
end)

it("lets game code own Signals and expose read-only Events through the root module", function()
	local rankChanged: KRF.Signal<number> = KRF.Signal.new()
	local ownedSignals: KRF.OwnedSignals = KRF.OwnedSignals.new({ rankChanged })
	local onRankChanged: KRF.Event<number> = KRF.Signal.wrapEvent(rankChanged)
	local received: { number } = {}

	local connection: KRF.Connection = onRankChanged:Connect(function(rank: number): ()
		table.insert(received, rank)
	end)

	ownedSignals:WithDeferredDestroy(function(): ()
		rankChanged:Fire(2)
	end)

	connection:Disconnect()
	ownedSignals:Destroy()

	local fireExposed: boolean = pcall(function(): ()
		local _: any = (onRankChanged :: any).Fire
	end)

	local connectedAfterDestroy: boolean = pcall(function(): ()
		onRankChanged:Connect(function(): () end)
	end)

	expect(received).toEqual({ 2 })
	expect(fireExposed).toBe(false)
	expect(connectedAfterDestroy).toBe(false)
end)
