--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local Types = require(KRF.client.ActionRequest.types)
local ActorTypes = require(KRF.client.Actor.types)
local NetworkingTypes = require(KRF.client.Networking.types)
local ActionRequestTypes = require(KRF.shared.ActionRequest.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Envelopes = require(KRF.shared.ActionRequest.utils.ActionCommandEnvelopes)
local Actor = require(KRF.client.Actor.ActorView)
local Registry = require(KRF.client.Actor.utils.ActorViewRegistryState)
local Runtime: Types.ClientActionRequestRuntimeModule = require(KRF.client.ActionRequest.ClientActionRequestRuntime)
local RequestUtils = require(script.Parent.Parent.Parent.shared.Utils.ActionRequestTestUtils)

export type Sent = {
	commandId: string,
	actor: ActorTypes.ActorView?,
	request: any,
	requestId: number,
}

-- A fake of the private N9 port: it allocates the next ID, consults admission before
-- recording physical egress, and lets tests deliver outcomes synchronously.
export type Port = {
	port: Types.ActionRequestCommandPort,
	sent: { Sent },
	order: { string },
	nextId: number,
	refusal: string?,
	-- Refuses after the admission callback ran, as N9 does when the client resets mid-send.
	refusalAfterAdmit: string?,
	onSend: ((Sent) -> ())?,
	observers: { (NetworkingTypes.CommandResult) -> () },
}

export type Fixture = {
	port: Port,
	runtime: Types.ClientActionRequestRuntime,
	catalog: ActionRequestTypes.ActionRequestCatalog,
	actor: ActorTypes.ActorViewOwner,
	owners: { ActorTypes.ActorViewOwner },
}

local TestUtils = {}

function TestUtils.port(): Port
	local fake: Port = {
		port = {} :: Types.ActionRequestCommandPort,
		sent = {},
		order = {},
		nextId = 1,
		refusal = nil,
		refusalAfterAdmit = nil,
		onSend = nil,
		observers = {},
	}

	fake.port = table.freeze({
		SendAdmitted = function(
			commandId: string,
			actor: ActorTypes.ActorView?,
			request: any,
			admit: NetworkingTypes.CommandAdmission
		): (number?, string?)
			if fake.refusal ~= nil then
				return nil, fake.refusal
			end

			local requestId: number = fake.nextId

			if not admit(requestId) then
				return nil, "CommandAdmissionRefused"
			elseif fake.refusalAfterAdmit ~= nil then
				return nil, fake.refusalAfterAdmit
			end

			fake.nextId += 1

			local sent: Sent = { commandId = commandId, actor = actor, request = request, requestId = requestId }
			table.insert(fake.sent, sent)
			table.insert(fake.order, "Sent:" .. commandId .. ":" .. requestId)

			if fake.onSend ~= nil then
				fake.onSend(sent)
			end

			return requestId, nil
		end,
		ObserveOutcomes = function(observer: (NetworkingTypes.CommandResult) -> ()): () -> ()
			table.insert(fake.observers, observer)

			return function(): ()
				local index: number? = table.find(fake.observers, observer)

				if index ~= nil then
					table.remove(fake.observers, index)
				end
			end
		end,
	})

	return fake
end

function TestUtils.view(fixture: Fixture?, actorId: string): ActorTypes.ActorViewOwner
	local owner: ActorTypes.ActorViewOwner = assert(Actor.new(actorId, nil, {}))
	assert(Registry.Install(owner.view))

	if fixture ~= nil then
		table.insert(fixture.owners, owner)
	end

	return owner
end

function TestUtils.new(
	schemas: ActionRequestTypes.ActionRequestSchemas?,
	options: { maxOriginalStarts: number? }?
): Fixture
	Registry.Reset()
	local port: Port = TestUtils.port()
	local catalog: ActionRequestTypes.ActionRequestCatalog = RequestUtils.catalog(schemas or RequestUtils.schemas())

	local fixture: Fixture = {
		port = port,
		runtime = Runtime.new(catalog, {
			commands = port.port,
			incarnation = 1,
			maxOriginalStarts = if options ~= nil then options.maxOriginalStarts else nil,
		}),
		catalog = catalog,
		actor = TestUtils.view(nil, "ActorA"),
		owners = {},
	}

	table.insert(fixture.owners, fixture.actor)

	return fixture
end

function TestUtils.selection(
	fixture: Fixture,
	actionId: string,
	actor: ActorTypes.ActorView?
): Types.ActionStartSelection
	return { actor = actor or fixture.actor.view, actionId = actionId, origin = "Input", inputTimestamp = 12.5 }
end

function TestUtils.deliver(
	fixture: Fixture,
	requestId: number,
	commandId: string,
	status: "Accepted" | "Rejected" | "Unknown",
	result: any?,
	reason: string?
): ()
	local message: NetworkingTypes.CommandResult = table.freeze({
		requestId = requestId,
		commandId = commandId,
		targetActorView = nil,
		status = status,
		result = result,
		reason = reason,
	})

	for _, observer: (NetworkingTypes.CommandResult) -> () in table.clone(fixture.port.observers) do
		observer(message)
	end
end

-- Bootstrap entries a server with request schemas publishes beside a consumer Game.Ping,
-- in the server's sorted code order.
function TestUtils.manifestCommands(): { SharedNetworkingTypes.ManifestCommand }
	local commands: { SharedNetworkingTypes.ManifestCommand } = { { id = "Game.Ping", code = 0, target = "None" } }

	for _, envelope in { Envelopes.Interrupt, Envelopes.Start, Envelopes.Stop } do
		table.insert(commands, {
			id = envelope.id,
			code = #commands,
			target = envelope.target,
			request = envelope.request,
			result = envelope.result,
		})
	end

	return commands
end

function TestUtils.destroy(fixture: Fixture?): ()
	if fixture == nil then
		return
	end

	fixture.runtime:Destroy()

	for _, owner: ActorTypes.ActorViewOwner in fixture.owners do
		owner:Destroy()
	end

	Registry.Reset()
end

return TestUtils
