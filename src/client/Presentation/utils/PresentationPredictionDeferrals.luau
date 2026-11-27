--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)

type Definition = Types.PresentationDefinition

export type DeferralMatch = "Adopt" | "Hold" | "Release"

export type DeferralOptions = {
	read Delay: (number, () -> ()) -> () -> (),
	read WindowSeconds: number,
	read Capacity: number,
	read Classify: (
		ActorTypes.ActorView,
		ActorTypes.ActionSnapshot
	) -> (DeferralMatch, (({ Definition }, (Definition) -> ()) -> ())?),
}

export type Deferrals = {
	read Hold: (Types.ActionEntryEvent, { Definition }, (Definition) -> ()) -> boolean,
	read Resolve: (ActorTypes.ActorView) -> (),
	read Drop: (ActorTypes.ActorView) -> (),
	read Destroy: () -> (),
}

type Held = {
	entry: Types.ActionEntryEvent,
	definitions: { Definition },
	deliver: (Definition) -> (),
	cancel: (() -> ())?,
	open: boolean,
}

local Deferrals = {}

function Deferrals.new(options: DeferralOptions): Deferrals
	local byActor: { [ActorTypes.ActorView]: { Held } } = {}
	local count: number = 0

	local function close(actor: ActorTypes.ActorView, held: Held): ()
		local records: { Held } = assert(byActor[actor], "Held Start must be indexed by its Actor")

		held.open = false
		count -= 1
		table.remove(records, assert(table.find(records, held), "Held Start must be indexed"))

		if #records == 0 then
			byActor[actor] = nil
		end

		local cancel: (() -> ())? = held.cancel

		held.cancel = nil

		if cancel ~= nil then
			cancel()
		end
	end

	local function release(actor: ActorTypes.ActorView, held: Held): ()
		close(actor, held)

		for _, definition: Definition in held.definitions do
			held.deliver(definition)
		end
	end

	local function resolve(actor: ActorTypes.ActorView): ()
		for _, held: Held in table.clone(byActor[actor] or {}) do
			if held.open then
				local match: DeferralMatch, adopt: (({ Definition }, (Definition) -> ()) -> ())? =
					options.Classify(actor, held.entry.action)

				if match == "Adopt" then
					close(actor, held)
					assert(adopt, "Adopt requires an adoption")(held.definitions, held.deliver)
				elseif match == "Release" then
					release(actor, held)
				end
			end
		end
	end

	local function drop(actor: ActorTypes.ActorView): ()
		for _, held: Held in table.clone(byActor[actor] or {}) do
			close(actor, held)
		end
	end

	return table.freeze({
		Hold = function(
			entry: Types.ActionEntryEvent,
			definitions: { Definition },
			deliver: (Definition) -> ()
		): boolean
			if count >= options.Capacity then
				return false
			end

			local actor: ActorTypes.ActorView = entry.actor

			local held: Held =
				{ entry = entry, definitions = definitions, deliver = deliver, cancel = nil, open = true }

			local records: { Held } = byActor[actor] or {}

			byActor[actor] = records
			count += 1
			table.insert(records, held)

			held.cancel = options.Delay(options.WindowSeconds, function(): ()
				held.cancel = nil

				local match: DeferralMatch, adopt: (({ Definition }, (Definition) -> ()) -> ())? =
					options.Classify(actor, entry.action)

				if match == "Adopt" then
					close(actor, held)
					assert(adopt, "Adopt requires an adoption")(definitions, deliver)
				else
					release(actor, held)
				end
			end)

			return true
		end,
		Resolve = resolve,
		Drop = drop,
		Destroy = function(): ()
			for actor: ActorTypes.ActorView in table.clone(byActor) do
				drop(actor)
			end
		end,
	})
end

return table.freeze(Deferrals)
