--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Server = require(ReplicatedStorage.Packages.KRF.server)

Players.CharacterAutoLoads = false
local success: boolean, failure = Server.Init({})
assert(success, if failure ~= nil then failure.reason else "ManualServerStartupFailed")
