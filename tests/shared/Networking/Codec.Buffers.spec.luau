--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local TestUtils = require(script.Parent.Parent.Utils.Networking.CodecTestUtils)

it("writes at a non-zero offset without changing surrounding caller-owned bytes", function()
	local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(Schema.String(8))
	local size: number?, measureReason: string? = codec.Measure("hello")
	expect(measureReason).toBeNil()
	assert(size ~= nil, "Expected a measured size")
	local destination: buffer = buffer.create(size + 6)
	buffer.fill(destination, 0, 165)
	local offset: number?, reason: string? = codec.Write("hello", destination, 3)
	expect(reason).toBeNil()
	expect(offset).toBe(size + 3)
	expect(buffer.readstring(destination, 0, 3)).toBe(string.rep(string.char(165), 3))
	expect(buffer.readstring(destination, size + 3, 3)).toBe(string.rep(string.char(165), 3))
	local value: any, readOffset: number?, readReason: string? = codec.Read(destination, 3, size + 3)
	expect(value).toBe("hello")
	expect(readOffset).toBe(offset)
	expect(readReason).toBeNil()
end)

it("writes sequential codecs directly into one exact-sized buffer", function()
	local header: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(Schema.U16)
	local body: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(Schema.Array(Schema.String(8), 2))
	local value: { string } = { "first", "last" }
	local bodySize: number?, measureReason: string? = body.Measure(value)
	expect(measureReason).toBeNil()
	assert(bodySize ~= nil, "Expected measured body")
	local destination: buffer = buffer.create(2 + bodySize)
	local headerOffset: number?, headerReason: string? = header.Write(123, destination, 0)
	expect(headerOffset).toBe(2)
	expect(headerReason).toBeNil()
	local bodyOffset: number?, bodyReason: string? = body.Write(value, destination, headerOffset :: number)
	expect(bodyOffset).toBe(buffer.len(destination))
	expect(bodyReason).toBeNil()

	local decodedHeader: any, decodedHeaderOffset: number?, decodedHeaderReason: string? =
		header.Read(destination, 0, buffer.len(destination))

	local decodedBody: any, decodedBodyOffset: number?, decodedBodyReason: string? =
		body.Read(destination, decodedHeaderOffset :: number, buffer.len(destination))

	expect(decodedHeader).toBe(123)
	expect(decodedHeaderReason).toBeNil()
	expect(decodedBody).toEqual(value)
	expect(decodedBodyOffset).toBe(buffer.len(destination))
	expect(decodedBodyReason).toBeNil()
end)

it("detects insufficient destination capacity before touching the buffer", function()
	local codec: SharedNetworkingTypes.CompiledCodec =
		TestUtils.compile(Schema.Struct({ first = Schema.U32, last = Schema.String(8) }))

	local value: any = { first = 42, last = "hello" }
	local size: number?, measureReason: string? = codec.Measure(value)
	expect(measureReason).toBeNil()
	assert(size ~= nil, "Expected measured record")
	local destination: buffer = buffer.create(size - 1)
	buffer.fill(destination, 0, 165)
	local original: string = buffer.tostring(destination)
	local offset: number? = nil
	local reason: string? = nil

	local completed: boolean = pcall(function()
		offset, reason = codec.Write(value, destination, 0)
	end)

	expect(completed).toBe(true)
	expect(offset).toBeNil()
	expect(reason).toBe("CodecBufferTooSmall")
	expect(buffer.tostring(destination)).toBe(original)
end)

it("rejects invalid write offsets without changing the destination", function()
	local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(Schema.U8)
	local destination: buffer = buffer.create(4)
	buffer.fill(destination, 0, 165)
	local original: string = buffer.tostring(destination)

	for _, invalidOffset: number in { -1, 0.5, 5, math.huge, 0 / 0 } do
		local offset: number?, reason: string? = codec.Write(42, destination, invalidOffset)
		expect(offset).toBeNil()
		expect(reason).toBe("CodecWriteBoundsInvalid")
		expect(buffer.tostring(destination)).toBe(original)
	end
end)

it("reports the sum of fixed Struct fields without treating Optional fields as fixed", function()
	local fixed: SharedNetworkingTypes.CompiledCodec =
		TestUtils.compile(Schema.Struct({ active = Schema.Boolean, count = Schema.U16, amount = Schema.F64 }))

	local variable: SharedNetworkingTypes.CompiledCodec =
		TestUtils.compile(Schema.Struct({ value = Schema.Optional(Schema.U16) }))

	expect(fixed.fixedSizeBytes).toBe(11)
	expect(fixed.maxSizeBytes).toBe(11)
	expect(variable.fixedSizeBytes).toBeNil()
	TestUtils.expectRoundTrip(variable, {})
	TestUtils.expectRoundTrip(variable, { value = 65535 })
end)

it("supports zero-byte Structs at the end of the buffer", function()
	local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(Schema.Struct({}))
	local destination: buffer = buffer.create(2)
	local offset: number?, reason: string? = codec.Write({}, destination, 2)
	local value: any, readOffset: number?, readReason: string? = codec.Read(destination, 2, 2)
	expect(codec.fixedSizeBytes).toBe(0)
	expect(codec.maxSizeBytes).toBe(0)
	expect(offset).toBe(2)
	expect(reason).toBeNil()
	expect(value).toEqual({})
	expect(readOffset).toBe(2)
	expect(readReason).toBeNil()
end)

it("measures variable-sized values exactly across collection prefix width boundaries", function()
	for _, maximum: number in { 1, 255, 256, 65535, 65536 } do
		local codec: SharedNetworkingTypes.CompiledCodec = TestUtils.compile(Schema.String(maximum))
		TestUtils.expectRoundTrip(codec, "")
		TestUtils.expectRoundTrip(codec, string.rep("x", maximum))
	end
end)

it("does not mutate consumer tables while measuring or encoding unordered Maps", function()
	local codec: SharedNetworkingTypes.CompiledCodec =
		TestUtils.compile(Schema.Map(Schema.String(8), Schema.Struct({ count = Schema.U8 }), 2))

	local value: any = { alpha = { count = 0 }, beta = { count = 255 } }
	TestUtils.expectRoundTrip(codec, value)
	expect(value).toEqual({ alpha = { count = 0 }, beta = { count = 255 } })
	expect(table.isfrozen(value)).toBe(false)
	expect(table.isfrozen(value.alpha)).toBe(false)
end)
