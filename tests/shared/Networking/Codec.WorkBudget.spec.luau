--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local TestUtils = require(script.Parent.Parent.Utils.Networking.CodecTestUtils)

it("rejects excessive aggregate collection work before writing any destination bytes", function()
	local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(Schema.Struct({
		first = Schema.Optional(Schema.Array(Schema.Struct({}), 60000)),
		second = Schema.Array(Schema.Struct({}), 60000),
	}))

	local emptyRecord: any = {}
	local value: any = { first = table.create(60000, emptyRecord), second = table.create(60000, emptyRecord) }
	local destination: buffer = buffer.fromstring("unchanged")
	local size: number?, measureReason: string? = codec.Measure(value)
	local offset: number?, writeReason: string? = codec.Write(value, destination, 0)
	expect(size).toBeNil()
	expect(measureReason).toBe("CodecEncodeWorkExceeded")
	expect(offset).toBeNil()
	expect(writeReason).toBe("CodecEncodeWorkExceeded")
	expect(buffer.tostring(destination)).toBe("unchanged")
	TestUtils.expectRoundTrip(codec, { first = { {} }, second = { {}, {} } })
end)

it("round trips the collection work boundary with a fresh budget for every operation", function()
	local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(Schema.Array(Schema.Struct({}), 100000))
	local emptyRecord: any = {}
	local value: { any } = table.create(100000, emptyRecord)
	local encoded: buffer = TestUtils.encode(codec, value)

	for _ = 1, 2 do
		local decoded: any, offset: number?, reason: string? = codec.Read(encoded, 0, buffer.len(encoded))
		expect(#decoded).toBe(100000)
		expect(offset).toBe(buffer.len(encoded))
		expect(reason).toBeNil()
	end
end)
