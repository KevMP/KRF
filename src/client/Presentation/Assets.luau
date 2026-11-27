--!strict
local Types = require(script.Parent.types)
local AssetPreloader = require(script.Parent.utils.AssetPreloader)
local NativeContentPort = require(script.Parent.utils.NativeContentPort)

local Assets: Types.AssetsModule = AssetPreloader.new(NativeContentPort)

return Assets
