--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local RunService = game:GetService("RunService")

local function createNameplate(_view: KRF.ActorView): () end

local function findView(model: Model): KRF.ActorView?
	--@example 1

	return view
end

--@example 2

local function showStun(view: KRF.ActorView, stunIcon: ImageLabel): KRF.Connection
	--@example 3

	return connection
end

local function showMana(view: KRF.ActorView, manaFill: Frame): ()
	--@example 4
end
