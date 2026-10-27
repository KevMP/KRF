--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Handshake = require(KRF.server.Networking.ServerHandshake)
local Warnings = require(KRF.shared.Networking.utils.NetworkingWarnings)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local Domains = require(KRF.server.Replication.ReplicationDomainRegistry)
local ServerUtils = require(script.Parent.Parent.Utils.Networking.ServerProtocolTestUtils)
local Protocol = require(script.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)
local originalEmit = Warnings.Emit
local runtime: Types.ServerHandshake?
local player: Player
local protocol: SharedTypes.PreparedProtocol

beforeEach(function()
	Domains._resetForTests()
	protocol = ServerUtils.prepare({})
	player = Protocol.createPlayer()
	runtime = nil
end)

afterEach(function()
	Warnings.Emit = originalEmit

	if runtime ~= nil then
		runtime:Destroy()
	end

	player:Destroy()
	Domains._resetForTests()
end)

for _, behavior in { "throws", "yields" } do
	it("continues Ready observers when the diagnostic sink " .. behavior, function()
		local logs = 0

		Warnings.Emit = function()
			logs += 1

			if behavior == "throws" then
				error("BrokenDiagnosticSink")
			end

			coroutine.yield()
		end

		local created = Handshake.new(protocol, { SendReliable = function() end })
		runtime = created
		local followed = 0

		created:ObserveClientReady(function()
			error("ObserverFailure")
		end)

		created:ObserveClientReady(function()
			error("RepeatedObserverFailure")
		end)

		created:ObserveClientReady(function()
			followed += 1
		end)

		local dispatch = coroutine.create(function()
			created:Handle(player, Protocol.encode({ kind = "Hello", version = Constants.PROTOCOL_VERSION }))
			created:Handle(player, Protocol.encode({ kind = "Ready" }))
		end)

		expect((coroutine.resume(dispatch))).toBe(true)
		expect(coroutine.status(dispatch)).toBe("dead")
		expect(followed).toBe(1)
		expect(logs).toBe(1)
		expect(created:IsClientReady(player)).toBe(true)
	end)
end

it("returns the transport failure even when its error cannot be formatted", function()
	local output: { string? } = {}

	Warnings.Emit = function(_category: SharedTypes.DiagnosticWarning, reason: string?)
		table.insert(output, reason)
	end

	local failing = false

	local created = Handshake.new(protocol, {
		SendReliable = function()
			if failing then
				error(setmetatable({}, {
					__tostring = function()
						error("UnprintableError")
					end,
				}))
			end
		end,
	})

	runtime = created
	created:Handle(player, Protocol.encode({ kind = "Hello", version = Constants.PROTOCOL_VERSION }))
	created:Handle(player, Protocol.encode({ kind = "Ready" }))
	failing = true
	local success, reason = created:Send(player, buffer.create(0))
	expect(success).toBe(false)
	expect(reason).toBe("TransportSendFailed")
	expect(created:IsClientReady(player)).toBe(true)
	expect(output).toEqual({ "UnprintableDiagnostic" })
end)
