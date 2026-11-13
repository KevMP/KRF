--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.client.Actor.types)
local ActionTypes = require(KRF.client.Action.types)
local SignalTypes = require(KRF.shared.Signal.types)

export type View = {
	Log: (string) -> (),
	Observe: (ActionTypes.ActionRequestEvent) -> (),
	Bind: (ActorTypes.ActorView?, ActorTypes.ActorView?) -> (),
	Render: () -> (),
	Destroy: () -> (),
}

local Panel = {}

local function tagsText(actor: ActorTypes.ActorView?): string
	local names: { string } = {}

	if actor ~= nil then
		for _, tag: ActorTypes.ActiveTagSnapshot in actor:GetTags():GetActiveTags() do
			table.insert(
				names,
				tag.tagId
					.. (if tag.remainingDuration ~= nil then string.format(" %.1fs", tag.remainingDuration) else "")
			)
		end
	end

	return if #names == 0 then "none" else table.concat(names, ", ")
end

function Panel.new(): View
	local gui: ScreenGui = Instance.new("ScreenGui")
	gui.Name = "FireDemoPanel"
	gui.ResetOnSpawn = false
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function label(position: UDim2, size: UDim2): TextLabel
		local text: TextLabel = Instance.new("TextLabel")
		text.Position = position
		text.Size = size
		text.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
		text.BackgroundTransparency = 0.15
		text.TextColor3 = Color3.new(1, 1, 1)
		text.TextXAlignment = Enum.TextXAlignment.Left
		text.TextYAlignment = Enum.TextYAlignment.Top
		text.TextSize = 15
		text.Font = Enum.Font.Code
		text.TextWrapped = true
		text.Parent = gui

		return text
	end

	local status: TextLabel = label(UDim2.fromOffset(12, 12), UDim2.fromOffset(470, 190))
	local history: TextLabel = label(UDim2.fromOffset(12, 210), UDim2.fromOffset(470, 270))
	local lines: { string } = {}
	local connections: { SignalTypes.Connection } = {}
	local controlled: ActorTypes.ActorView? = nil
	local dummy: ActorTypes.ActorView? = nil

	local billboard: BillboardGui = Instance.new("BillboardGui")
	billboard.Name = "FireDemoDummyState"
	billboard.Size = UDim2.fromOffset(310, 70)
	billboard.StudsOffset = Vector3.new(0, 6, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local dummyText: TextLabel = label(UDim2.new(), UDim2.fromScale(1, 1))
	dummyText.Parent = billboard

	local function log(message: string): ()
		table.insert(lines, message)

		if #lines > 12 then
			table.remove(lines, 1)
		end

		history.Text = "Recent input / requests / replicated lifecycle\n" .. table.concat(lines, "\n")
		print("[FireDemo client] " .. message)
	end

	local function clear(): ()
		for _, connection: SignalTypes.Connection in connections do
			connection:Disconnect()
		end

		table.clear(connections)
	end

	return {
		Log = log,
		Observe = function(fact: ActionTypes.ActionRequestEvent): ()
			local prefix: string = string.format("#%d %s ", fact.eventOrdinal, fact.actionId)

			if fact.kind == "InputTransition" then
				log(prefix .. fact.transition .. " original=" .. fact.originalStartKey)
			elseif fact.kind == "RequestAdmitted" then
				log(prefix .. fact.operation .. " admitted key=" .. fact.requestKey)
			else
				log(
					prefix
						.. fact.operation
						.. " "
						.. fact.status
						.. " seq="
						.. tostring(fact.sequenceId)
						.. " "
						.. (fact.reason or "")
				)
			end
		end,
		Bind = function(actor, target): ()
			clear()
			controlled, dummy = actor, target

			if actor ~= nil then
				local actions: ActorTypes.ActionsView = actor:GetActions()

				local lifecycleEvents: { [string]: SignalTypes.Event<ActorTypes.ActionSnapshot> } = {
					Started = actions.OnActionStarted,
					Ended = actions.OnActionEnded,
					Interrupted = actions.OnActionInterrupted,
				}

				for name: string, event: SignalTypes.Event<ActorTypes.ActionSnapshot> in lifecycleEvents do
					table.insert(
						connections,
						event:Connect(function(snapshot: ActorTypes.ActionSnapshot): ()
							log("Replicated " .. name .. " " .. snapshot.actionId .. " seq=" .. snapshot.sequenceId)
						end)
					)
				end
			end

			if target ~= nil then
				local tags: ActorTypes.TagsView = target:GetTags()

				local tagEvents: { [string]: SignalTypes.Event<string> } = {
					Added = tags.OnTagAdded,
					Expired = tags.OnTagExpired,
					Removed = tags.OnTagRemoved,
				}

				for name: string, event: SignalTypes.Event<string> in tagEvents do
					table.insert(
						connections,
						event:Connect(function(tagId: string): ()
							log("Dummy Tag " .. name .. " " .. tagId)
						end)
					)
				end
			end
		end,
		Render = function(): ()
			local actions: { string } = {}

			if controlled ~= nil then
				for _, snapshot: ActorTypes.ActionSnapshot in controlled:GetActions():GetActiveActions() do
					table.insert(actions, snapshot.actionId .. " #" .. snapshot.sequenceId)
				end
			end

			status.Text = "KRF FIRE ACTIONS — click the game viewport\n"
				.. "F hold: Fire Breath / release: Stop\nQ: Fireball (one per press)\n"
				.. "X > Q > Z: Flame Strike only (gaps <0.6s)\nX > Q timeout: Fireball. WASD: move.\n"
				.. "Actor: "
				.. (if controlled ~= nil then "ready" else "waiting for character/view")
				.. "\nActive: "
				.. (if #actions == 0 then "none" else table.concat(actions, ", "))
				.. "\nYour Tags: "
				.. tagsText(controlled)
				.. "\nDummy Tags: "
				.. tagsText(dummy)

			local model: Model? = if dummy ~= nil then dummy:GetModel() else nil
			local body: Instance? = if model ~= nil then model:FindFirstChild("HumanoidRootPart") else nil

			billboard.Enabled = body ~= nil and body:IsA("BasePart")

			if body ~= nil and body:IsA("BasePart") then
				billboard.Adornee = body
			end

			dummyText.Text = "TRAINING DUMMY\n" .. tagsText(dummy)

			if body ~= nil and body:IsA("BasePart") and dummy ~= nil then
				local tags: ActorTypes.TagsView = dummy:GetTags()

				body.Color = if tags:HasTag("Stunned")
					then Color3.fromRGB(255, 220, 40)
					elseif tags:HasTag("Burning") then Color3.fromRGB(255, 90, 20)
					else Color3.fromRGB(100, 100, 100)
			end
		end,
		Destroy = function(): ()
			clear()
			billboard:Destroy()
			gui:Destroy()
		end,
	}
end

return Panel
