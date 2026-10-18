--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.client.Actor.types)
local Domains: Types.DomainViewModule = require(KRF.client.Actor.DomainView)
local Tags: Types.TagsViewModule = require(KRF.client.Actor.TagsView)

export type WireState = { [string]: { read stackCount: number, read expiresAt: number? } }
export type Fixture = {
	domain: Types.DomainViewOwner,
	owner: Types.TagsViewOwner,
	view: Types.TagsView,
	clock: { now: number },
}
local TestUtils = {}

function TestUtils.freeze(state: WireState): WireState
	local owned: WireState = {}
	for id: string, entry in state do
		owned[id] = table.freeze(table.clone(entry))
	end
	return table.freeze(owned)
end

function TestUtils.new(initial: WireState?): Fixture
	local domain: Types.DomainViewOwner?, reason: string? = Domains.new("KRF.Tags", TestUtils.freeze(initial or {}), {
		"Added",
		"Refreshed",
		"Removed",
		"Expired",
	})
	assert(domain ~= nil, reason)
	local clock = { now = 1000 }
	local owner: Types.TagsViewOwner = Tags.new(function(): Types.DomainView?
		return domain.view
	end, function(): number
		return clock.now
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
