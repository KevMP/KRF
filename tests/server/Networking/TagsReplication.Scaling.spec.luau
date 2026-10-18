--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local TagTypes = require(KRF.server.Tags.types)
local ServerTypes = require(KRF.server.Networking.types)
local TestUtils = require(script.Parent.Parent.Utils.Networking.TagsReplicationTestUtils)
local PublicationUtils = require(script.Parent.Parent.Utils.Networking.PublicationTestUtils)

local fixture: TestUtils.Fixture? = nil
local runtime: ServerTypes.PublicationRuntime? = nil

afterEach(function()
	if runtime ~= nil then
		runtime:Destroy()
		runtime = nil
	end

	if fixture ~= nil then
		TestUtils.destroy(fixture)
		fixture = nil
	end
end)

for _, activeCount: number in { 1, 64, 512 } do
	it("keeps a one-Tag patch and one controller query with " .. activeCount .. " visible IDs active", function()
		local definitions: { TagTypes.TagDefinition } = {}

		for index: number = 1, activeCount do
			local definition: TagTypes.TagDefinition = {
				id = string.format("Scale.Tag%04d", index),
				visibility = "ClientVisible",
				duplicateBehavior = "Refresh",
				defaultDuration = 60,
			}

			table.insert(definitions, definition)
		end

		local current: TestUtils.Fixture = TestUtils.new(definitions)
		fixture = current

		for _, definition: TagTypes.TagDefinition in definitions do
			TestUtils.add(current, definition.id)
		end

		local publication: ServerTypes.PublicationRuntime = PublicationUtils.createRuntime({ current.definition })
		runtime = publication
		local attached: boolean, reason: string? = publication:AttachActor(current.actor)
		expect(reason).toBeNil()
		expect(attached).toBe(true)
		local commits: { ServerTypes.PublicationCommit } = {}

		publication:ObserveCommits(function(commit: ServerTypes.PublicationCommit)
			table.insert(commits, commit)
		end)

		local queries: { string } = {}
		local originalInstances = current.tags.GetTagInstances

		current.tags.GetTagInstances = function(
			self: TagTypes.InternalTagController,
			id: string
		): { TagTypes.TagInstanceSnapshot }
			table.insert(queries, id)

			return originalInstances(self, id)
		end

		current.tags.GetActiveTags = function(): { TagTypes.ActiveTagSnapshot }
			error("MutationMustNotEnumerateAllControllerTags")
		end

		current.clock.now = 1001
		TestUtils.add(current, "Scale.Tag0001", 90)
		expect(queries).toEqual({ "Scale.Tag0001" })
		expect(#commits).toBe(1)

		expect(commits[1].patches).toEqual({
			{
				domainId = "KRF.Tags",
				patch = {
					kind = "Map",
					entries = { ["Scale.Tag0001"] = { stackCount = 1, expiresAt = 1091 } },
					removed = {},
				},
			},
		})

		expect(commits[1].events).toEqual({
			{ domainId = "KRF.Tags", eventId = "Refreshed", payload = "Scale.Tag0001" },
		})

		local baseline: ServerTypes.PublicationBaseline? = publication:CaptureBaseline(current.actor)
		expect(baseline).never.toBeNil()
		assert(baseline ~= nil, "Expected the complete canonical baseline after refresh")
		local expected: { [string]: { stackCount: number, expiresAt: number } } = {}

		for _, definition: TagTypes.TagDefinition in definitions do
			expected[definition.id] =
				{ stackCount = 1, expiresAt = if definition.id == "Scale.Tag0001" then 1091 else 1060 }
		end

		expect(baseline.domains["KRF.Tags"].value).toEqual(expected)
		-- This proves query/patch scope, not constant CPU cost: ordinary publication still
		-- captures and measures the complete visible Map. Timings live separately.
	end)
end
