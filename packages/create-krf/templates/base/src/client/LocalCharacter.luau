--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local LocalCharacter = {}

local player: Player = Players.LocalPlayer
local observers: { (KRF.ActorView) -> () } = {}
local current: KRF.ActorView? = nil
local started: boolean = false

function LocalCharacter.Get(): KRF.ActorView?
	local character: Model? = player.Character

	return if character ~= nil then KRF.ActorViewRegistry.GetActorViewByModel(character) else nil
end

function refresh(): ()
	local view: KRF.ActorView? = LocalCharacter.Get()

	if view ~= nil and view ~= current then
		current = view

		for _, observer in observers do
			observer(view)
		end
	end
end

function watch(view: KRF.ActorView): ()
	view.OnModelChanged:Connect(refresh)
end

function forget(view: KRF.ActorView): ()
	if view == current then
		current = nil
	end
end

function start(): ()
	started = true

	KRF.ActorViewRegistry.OnActorViewAdded:Connect(function(view: KRF.ActorView)
		watch(view)
		refresh()
	end)
	KRF.ActorViewRegistry.OnActorViewRemoving:Connect(forget)
	player.CharacterAdded:Connect(refresh)

	for _, view: KRF.ActorView in KRF.ActorViewRegistry.GetAllActorViews() do
		watch(view)
	end
end

function LocalCharacter.Observe(observer: (KRF.ActorView) -> ()): ()
	table.insert(observers, observer)

	if not started then
		start()
	end

	if current ~= nil then
		observer(current)
	end

	refresh()
end

return LocalCharacter
