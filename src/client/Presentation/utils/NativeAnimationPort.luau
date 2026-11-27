--!strict
local Types = require(script.Parent.Parent.types)

local NativeAnimationPort: Types.AnimationTrackPort = table.freeze({
	Load = function(animator: Animator, animation: Animation): AnimationTrack
		return animator:LoadAnimation(animation)
	end,
	GetPlayingTracks = function(animator: Animator): { AnimationTrack }
		return animator:GetPlayingAnimationTracks()
	end,
})

return NativeAnimationPort
