--!strict
local Types = require(script.Parent.types)
local AnimationTrackCache = require(script.Parent.utils.AnimationTrackCache)
local AnimationPlayer = require(script.Parent.utils.AnimationPlayer)
local NativeAnimationPort = require(script.Parent.utils.NativeAnimationPort)

local Animations: Types.AnimationsModule = AnimationPlayer.new(AnimationTrackCache.new(NativeAnimationPort))

return Animations
