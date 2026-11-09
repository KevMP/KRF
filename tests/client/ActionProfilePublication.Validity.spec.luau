--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: (string, () -> ()) -> () = (JestGlobals.it :: unknown) :: (string, () -> ()) -> ()
local expect = JestGlobals.expect
local afterEach: (() -> ()) -> () = (JestGlobals.afterEach :: unknown) :: (() -> ()) -> ()
local Types = require(KRF.client.Action.types)
local ActorTypes = require(KRF.client.Actor.types)
local InputTypes = require(KRF.client.Input.types)
local Graph = require(KRF.client.Action.utils.ActionProfileGraph)
local Publication = require(KRF.client.Action.utils.ActionProfilePublication)
local Actor = require(KRF.client.Actor.ActorView)
local Utils = require(script.Parent.Utils.InputTestUtils)
local fixture: Utils.Fixture? = nil
local actor: ActorTypes.ActorViewOwner? = nil

afterEach(function()
	if actor ~= nil then
		actor:Destroy()
		actor = nil
	end

	if fixture ~= nil then
		Utils.destroy(fixture)
		fixture = nil
	end
end)

for _, failure: string in { "Unavailable", "DependencyRemoved" } do
	it("revalidates " .. failure .. " before installing a prepared profile catalog", function()
		local created: Utils.Fixture = Utils.new()
		fixture = created
		Utils.install(created)
		Utils.enable(created)
		local view: ActorTypes.ActorViewOwner = assert(Actor.new("ProfileActor", nil, {}), "Expected Actor")
		actor = view
		local available: boolean = true
		local installed: number = 0
		local catalog: Graph.Catalog = {}

		local owner: Publication.Owner = Publication.new(created.owner, {
			Current = function(): Graph.Catalog
				return catalog
			end,
			Selected = function(): ActorTypes.ActorView?
				return nil
			end,
			Version = function(): number
				return 1
			end,
			ValidateActor = function(): string?
				return nil
			end,
			Available = function(): boolean
				return available
			end,
			Install = function(nextCatalog): ()
				catalog = nextCatalog
				installed += 1
			end,
			Notify = function() end,
		})

		local profiles: Types.PreparedProfileGraph = assert(
			owner.Prepare({
				{
					actor = view.view,
					sourceId = "Base",
					profile = {
						routes = {
							{
								when = { kind = "Input", inputId = "Primary", gesture = "Pressed" },
								target = { kind = "Fixed", actionId = "Combat.Fireball" },
							},
						},
					},
				},
			}),
			"Expected profile plan"
		)

		if failure == "Unavailable" then
			available = false
		end

		local plan: InputTypes.PreparedInputUpdate = assert(
			created.owner.PrepareSource(
				if failure == "DependencyRemoved" then "Core" else "Empty",
				if failure == "DependencyRemoved" then nil else {}
			),
			"Expected input plan"
		)

		expect({
			created.owner.CommitPreparedWithPublication(plan, function(): ()
				expect({ owner.Commit(profiles) }).toEqual({
					false,
					if failure == "Unavailable" then "ActorViewUnavailable" else "ProfileDependencyMissing",
				})
			end),
		}).toEqual({ true })

		expect(installed).toBe(0)
		owner.Release(profiles)
		owner.Clear()
	end)
end
