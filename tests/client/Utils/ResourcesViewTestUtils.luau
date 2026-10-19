--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.client.Actor.types)
local Domains: Types.DomainViewModule = require(KRF.client.Actor.DomainView)
local Resources: Types.ResourcesViewModule = require(KRF.client.Actor.ResourcesView)

export type WireEntry = {
	read anchorValue: number,
	read anchorTime: number,
	read min: number,
	read max: number,
	read regenRate: number?,
}

export type WireState = { [string]: WireEntry }

export type Fixture = {
	domain: Types.DomainViewOwner,
	owner: Types.ResourcesViewOwner,
	view: Types.ResourcesView,
	clock: { now: number, reads: number, increment: number },
}

local TestUtils = {}

function TestUtils.freeze(state: WireState): WireState
	local owned: WireState = {}

	for id: string, entry: WireEntry in state do
		owned[id] = table.freeze(table.clone(entry))
	end

	return table.freeze(owned)
end

function TestUtils.new(initial: WireState?): Fixture
	local domain: Types.DomainViewOwner?, reason: string? = Domains.new(
		"KRF.Resources",
		TestUtils.freeze(initial or {
			["Resource.Mana"] = { anchorValue = 40, anchorTime = 1000, min = 0, max = 100, regenRate = 10 },
		}),
		{}
	)

	assert(domain ~= nil, reason)
	local clock = { now = 1000, reads = 0, increment = 0 }

	local owner: Types.ResourcesViewOwner = Resources.new(function(): Types.DomainView?
		return domain.view
	end, function(): number
		clock.reads += 1

		return clock.now + (clock.reads - 1) * clock.increment
	end)

	return { domain = domain, owner = owner, view = owner.view, clock = clock }
end

function TestUtils.install(fixture: Fixture, state: WireState, source: Types.DomainChangeSource): ()
	local previous: any = fixture.domain.view:GetState()
	local current: WireState = TestUtils.freeze(state)
	fixture.domain:InstallState(current)
	fixture.domain:NotifyChanged(table.freeze({ previous = previous, current = current, source = source }))
end

function TestUtils.destroy(fixture: Fixture): ()
	fixture.owner:Destroy()
	fixture.domain:Destroy()
end

return TestUtils
