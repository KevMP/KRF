--!strict
local Types = require(script.Parent.Parent.types)
local Validator = require(script.Parent.Parent.AnimationPlayValidator)

local TRACK_LIMIT: number = 32

type Entry = {
	animationId: string,
	animation: Animation,
	track: AnimationTrack,
	generation: number,
	lastUsed: number,
	disposed: boolean,
}

type AnimatorRecord = {
	rig: Types.AnimationRig,
	entries: { [string]: Entry },
	count: number,
	connections: { RBXScriptConnection },
}

type CacheState = {
	port: Types.AnimationTrackPort,
	records: { [Animator]: AnimatorRecord },
	clock: number,
}

local AnimationTrackCache = {}

local function dispose(entry: Entry): ()
	entry.disposed = true

	pcall(function(): ()
		entry.track:Stop(0)
	end)

	pcall(function(): ()
		entry.track:Destroy()
	end)

	pcall(function(): ()
		entry.animation:Destroy()
	end)
end

local function release(state: CacheState, record: AnimatorRecord): ()
	state.records[record.rig.animator] = nil

	for _, connection: RBXScriptConnection in record.connections do
		connection:Disconnect()
	end

	table.clear(record.connections)

	for _, entry: Entry in record.entries do
		dispose(entry)
	end

	table.clear(record.entries)
	record.count = 0
end

local function forget(record: AnimatorRecord, entry: Entry): ()
	record.entries[entry.animationId] = nil
	record.count -= 1
	dispose(entry)
end

local function releaseIfEmpty(state: CacheState, record: AnimatorRecord): ()
	if record.count == 0 then
		release(state, record)
	end
end

local function attached(rig: Types.AnimationRig): boolean
	return rig.animator.Parent == rig.controller
		and rig.controller.Parent == rig.model
		and rig.animator:IsDescendantOf(game)
end

local function watch(state: CacheState, rig: Types.AnimationRig): AnimatorRecord
	local record: AnimatorRecord = { rig = rig, entries = {}, count = 0, connections = {} }

	state.records[rig.animator] = record

	table.insert(
		record.connections,
		rig.animator.Destroying:Connect(function(): ()
			release(state, record)
		end)
	)

	table.insert(
		record.connections,
		rig.animator.AncestryChanged:Connect(function(): ()
			if not attached(rig) then
				release(state, record)
			end
		end)
	)

	return record
end

local function evict(state: CacheState, record: AnimatorRecord): boolean
	local busy: { [AnimationTrack]: boolean } = {}
	local playing: boolean, tracks: { AnimationTrack } = pcall(state.port.GetPlayingTracks, record.rig.animator)

	if not playing then
		return false
	end

	for _, active: AnimationTrack in tracks do
		busy[active] = true
	end

	local candidate: Entry? = nil

	for _, entry: Entry in record.entries do
		local idle: boolean = not busy[entry.track] and not entry.track.IsPlaying

		if idle and (candidate == nil or entry.lastUsed < candidate.lastUsed) then
			candidate = entry
		end
	end

	if candidate == nil then
		return false
	end

	forget(record, candidate)

	return true
end

local function load(state: CacheState, record: AnimatorRecord, animationId: string): (Entry?, string?)
	if record.count >= TRACK_LIMIT and not evict(state, record) then
		return nil, "AnimationCacheFull"
	end

	local animation: Animation = Instance.new("Animation")
	animation.AnimationId = animationId

	local loaded: boolean, result: unknown = pcall(state.port.Load, record.rig.animator, animation)

	if not loaded then
		animation:Destroy()

		return nil, "AnimationLoadFailed"
	end

	local entry: Entry = {
		animationId = animationId,
		animation = animation,
		track = result :: AnimationTrack,
		generation = 0,
		lastUsed = 0,
		disposed = false,
	}

	record.entries[animationId] = entry
	record.count += 1

	return entry, nil
end

local function handle(entry: Entry, generation: number, fadeTime: number): Types.AnimationPlayback
	local retired: boolean = false
	local animationTrack: AnimationTrack = entry.track

	local function current(): boolean
		return not retired and not entry.disposed and entry.generation == generation
	end

	local function stop(stopFadeTime: number?): ()
		if stopFadeTime ~= nil and not Validator.IsFadeTime(stopFadeTime) then
			error("AnimationFadeTimeInvalid", 3)
		elseif not current() then
			return
		end

		retired = true

		pcall(function(): ()
			animationTrack:Stop(if stopFadeTime ~= nil then stopFadeTime else fadeTime)
		end)
	end

	return table.freeze({
		Stop = function(_self: Types.AnimationPlayback, stopFadeTime: number?): ()
			stop(stopFadeTime)
		end,
		Destroy = function(_self: Types.AnimationPlayback): ()
			stop(nil)
		end,
		AdjustSpeed = function(_self: Types.AnimationPlayback, speed: number): ()
			if not Validator.IsSpeed(speed) then
				error("AnimationSpeedInvalid", 2)
			elseif current() and animationTrack.IsPlaying then
				pcall(function(): ()
					animationTrack:AdjustSpeed(speed)
				end)
			end
		end,
		AdjustWeight = function(_self: Types.AnimationPlayback, weight: number, weightFadeTime: number?): ()
			if not Validator.IsWeight(weight) then
				error("AnimationWeightInvalid", 2)
			elseif weightFadeTime ~= nil and not Validator.IsFadeTime(weightFadeTime) then
				error("AnimationFadeTimeInvalid", 2)
			elseif current() and animationTrack.IsPlaying then
				pcall(function(): ()
					animationTrack:AdjustWeight(weight, weightFadeTime)
				end)
			end
		end,
		GetTrack = function(_self: Types.AnimationPlayback): AnimationTrack?
			return if current() then animationTrack else nil
		end,
	})
end

local function start(entry: Entry, options: Types.CompiledAnimationPlayOptions): boolean
	local animationTrack: AnimationTrack = entry.track

	local started: boolean = pcall(function(): ()
		animationTrack:Play(options.fadeTime, options.weight, options.speed)
	end)

	if started then
		pcall(function(): ()
			animationTrack.Priority = options.priority
			animationTrack.Looped = options.looped
			animationTrack.TimePosition = if options.speed < 0 then animationTrack.Length else 0
		end)
	end

	return started
end

function AnimationTrackCache.new(port: Types.AnimationTrackPort): Types.AnimationTrackCache
	local state: CacheState = { port = port, records = {}, clock = 0 }

	local cache: Types.AnimationTrackCache = table.freeze({
		Play = function(
			_self: Types.AnimationTrackCache,
			rig: Types.AnimationRig,
			animationId: string,
			options: Types.CompiledAnimationPlayOptions
		): (Types.AnimationPlayback?, string?)
			local record: AnimatorRecord = state.records[rig.animator] or watch(state, rig)
			local entry: Entry? = record.entries[animationId]

			if entry == nil then
				local loaded: Entry?, reason: string? = load(state, record, animationId)

				if loaded == nil then
					releaseIfEmpty(state, record)

					return nil, reason
				end

				entry = loaded
			end

			local playing: Entry = entry :: Entry

			if not start(playing, options) then
				if playing.generation == 0 then
					forget(record, playing)
					releaseIfEmpty(state, record)
				end

				return nil, "AnimationPlayFailed"
			end

			state.clock += 1
			playing.generation += 1
			playing.lastUsed = state.clock

			return handle(playing, playing.generation, options.fadeTime), nil
		end,
		Holds = function(_self: Types.AnimationTrackCache, animator: Animator): boolean
			return state.records[animator] ~= nil
		end,
		_CountForTests = function(_self: Types.AnimationTrackCache): (number, number)
			local animators: number = 0
			local tracks: number = 0

			for _, record: AnimatorRecord in state.records do
				animators += 1
				tracks += record.count
			end

			return animators, tracks
		end,
	})

	return cache
end

return table.freeze(AnimationTrackCache)
