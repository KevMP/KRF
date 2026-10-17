--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.server.Networking.AwarenessTypes)
local Association: Types.AssociationModule = require(KRF.server.Networking.NativePlayerAssociation)
local SignalTypes = require(KRF.shared.Signal.types)
local SignalModule = require(KRF.shared.Signal.SignalModule)

local player: Player
local oldCharacter: Model
local newCharacter: Model
local added: SignalTypes.Signal<Player>
local removed: SignalTypes.Signal<Player>
local service: Players
local source: Types.AssociationSource?
local propertySignals: { BindableEvent } = {}

local function injectedPlayer(): Player
	local character: Model? = nil
	local changed: BindableEvent = Instance.new("BindableEvent")
	table.insert(propertySignals, changed)
	return setmetatable({
		GetPropertyChangedSignal = function(_self: any, property: string)
			assert(property == "Character", "Expected production Character property observer")
			return changed.Event
		end,
	}, {
		__index = function(_self: any, key: string): any
			return if key == "Character" then character else nil
		end,
		__newindex = function(_self: any, key: string, value: Model?)
			assert(key == "Character", "Unexpected Player mutation")
			if character ~= value then
				character = value
				changed:Fire()
			end
		end,
	}) :: any
end

beforeEach(function()
	player = injectedPlayer()
	oldCharacter = Instance.new("Model")
	newCharacter = Instance.new("Model")
	added = SignalModule.new()
	removed = SignalModule.new()
	service = {
		PlayerAdded = added,
		PlayerRemoving = removed,
		GetPlayers = function()
			return { player }
		end,
	} :: any
	source = nil
end)
afterEach(function()
	if source ~= nil then
		source.Destroy()
	end
	for _, signal: BindableEvent in propertySignals do
		signal:Destroy()
	end
	propertySignals = {}
	oldCharacter:Destroy()
	newCharacter:Destroy()
	added:Destroy()
	removed:Destroy()
end)

it("observes the Character property and notifies both Models through old-to-new-to-nil transitions", function()
	player.Character = oldCharacter
	local native: Types.AssociationSource = Association.new(service)
	source = native
	expect(native.GetPlayerFromCharacter(oldCharacter)).toBe(player)
	expect(native.GetPlayerFromCharacter(newCharacter)).toBeNil()
	local changed: { Model } = {}
	local unsubscribe: () -> () = native.ObserveAssociationChanged(function(model: Model)
		table.insert(changed, model)
	end)
	player.Character = newCharacter
	task.wait()
	expect(changed).toEqual({ oldCharacter, newCharacter })
	expect(native.GetPlayerFromCharacter(oldCharacter)).toBeNil()
	expect(native.GetPlayerFromCharacter(newCharacter)).toBe(player)
	player.Character = newCharacter
	added:Fire(player)
	task.wait()
	expect(changed).toEqual({ oldCharacter, newCharacter })
	player.Character = nil
	task.wait()
	expect(changed).toEqual({ oldCharacter, newCharacter, newCharacter })
	expect(native.GetPlayerFromCharacter(newCharacter)).toBeNil()
	unsubscribe()
	unsubscribe()
	player.Character = oldCharacter
	task.wait()
	expect(#changed).toBe(3)
end)

it("tracks a later Player and clears its Character association when that session leaves", function()
	local later: Player = injectedPlayer()
	local native: Types.AssociationSource = Association.new(service)
	source = native
	later.Character = newCharacter
	local changed: { Model } = {}
	native.ObserveAssociationChanged(function(model: Model)
		table.insert(changed, model)
	end)
	added:Fire(later)
	task.wait()
	expect(native.GetPlayerFromCharacter(newCharacter)).toBe(later)
	removed:Fire(later)
	removed:Fire(later)
	removed:Fire(player)
	task.wait()
	expect(native.GetPlayerFromCharacter(newCharacter)).toBeNil()
	expect(changed).toEqual({ newCharacter, newCharacter })
	later.Character = oldCharacter
	task.wait()
	expect(native.GetPlayerFromCharacter(oldCharacter)).toBeNil()
end)

it("releases native listeners and observers on repeated teardown", function()
	player.Character = oldCharacter
	local native: Types.AssociationSource = Association.new(service)
	source = native
	local calls: number = 0
	local unsubscribe: () -> () = native.ObserveAssociationChanged(function(_model: Model)
		calls += 1
	end)
	native.Destroy()
	native.Destroy()
	player.Character = newCharacter
	added:Fire(player)
	removed:Fire(player)
	task.wait()
	expect(calls).toBe(0)
	expect(native.GetPlayerFromCharacter(oldCharacter)).toBeNil()
	expect(native.GetPlayerFromCharacter(newCharacter)).toBeNil()
	unsubscribe()
	unsubscribe()
	local afterDestroy: () -> () = native.ObserveAssociationChanged(function(_model: Model)
		calls += 1
	end)
	afterDestroy()
end)
