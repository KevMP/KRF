--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local TagTypes = require(KRF.server.Tags.types)
local PropertyTypes = require(KRF.server.Property.types)
local ResourceTypes = require(KRF.server.Resource.types)
local ActionUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)

type Observer = { Commit: (...any) -> (), Dispatch: () -> () }
local disconnects: { () -> () } = {}

beforeEach(function()
	ActionUtils.reset()
	disconnects = {}
end)

afterEach(function()
	for _, disconnect in disconnects do
		disconnect()
	end

	ActionUtils.cleanup()
end)

for _, source: string in { "Tag", "Property", "Resource" } do
	for _, phase: string in { "Commit", "Dispatch" } do
		it(`snapshots {source} {phase} registrations, skips replacements, and ignores stale disconnects`, function()
			ActionUtils.initialize({}, {
				{
					id = "Mana",
					visibility = "ClientVisible",
					autoAssign = true,
					initialValue = 100,
					max = { value = 100 },
				},
			}, {
				{ id = "Marker", visibility = "ClientVisible", duplicateBehavior = "Stack" },
			})

			local _, _, publicResources: ResourceTypes.ResourceController, publicProperties: PropertyTypes.PropertyController, publicTags: TagTypes.TagController =
				ActionUtils.registerActor()

			local tags: TagTypes.InternalTagController = publicTags :: TagTypes.InternalTagController

			local properties: PropertyTypes.InternalPropertyController =
				publicProperties :: PropertyTypes.InternalPropertyController

			local resources: ResourceTypes.InternalResourceController =
				publicResources :: ResourceTypes.InternalResourceController

			local register: (Observer) -> () -> ()

			if source == "Tag" then
				register = function(observer: Observer): () -> ()
					return tags:_observeMutations(observer)
				end
			elseif source == "Property" then
				register = function(observer: Observer): () -> ()
					return properties:_observeResolvedMutations(observer)
				end
			else
				register = function(observer: Observer): () -> ()
					return resources:_observeMutations(observer)
				end
			end

			local generation: number = 0

			local function mutate(): ()
				generation += 1

				if source == "Tag" then
					expect(tags:AddTag("Marker")).toBe(true)
				elseif source == "Property" then
					expect(properties:SetBaseProperty("WalkSpeed", 16 + generation)).toBe(true)
				else
					expect(resources:Spend("Mana", 1)).toBe(true)
				end
			end

			local observers: { Observer } = {}
			local originals: { () -> () } = {}
			local deliveries: { number } = {}
			local replaced: boolean = false

			local newcomer: Observer = {
				Commit = function(): ()
					if phase == "Commit" then
						table.insert(deliveries, 4)
					end
				end,
				Dispatch = function(): ()
					if phase == "Dispatch" then
						table.insert(deliveries, 4)
					end
				end,
			}

			for index = 1, 3 do
				local function delivered(): ()
					table.insert(deliveries, index)

					if replaced then
						return
					end

					replaced = true

					for _, disconnect in originals do
						disconnect()
					end

					for _, observer: Observer in observers do
						table.insert(disconnects, register(observer))
					end

					table.insert(disconnects, register(newcomer))

					for _, disconnect in originals do
						disconnect()
					end
				end

				local observer: Observer = {
					Commit = function(): ()
						if phase == "Commit" then
							delivered()
						end
					end,
					Dispatch = function(): ()
						if phase == "Dispatch" then
							delivered()
						end
					end,
				}

				table.insert(observers, observer)
				table.insert(originals, register(observer))
			end

			mutate()
			expect(#deliveries).toBe(1)
			table.clear(deliveries)
			mutate()
			table.sort(deliveries)
			expect(deliveries).toEqual({ 1, 2, 3, 4 })

			for _, disconnect in disconnects do
				disconnect()
				disconnect()
			end

			table.clear(deliveries)
			mutate()
			expect(deliveries).toEqual({})
		end)
	end
end
