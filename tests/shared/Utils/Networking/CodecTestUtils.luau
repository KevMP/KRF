--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local NetworkingTypes = require(KRF.shared.Networking.types)
local Compiler: NetworkingTypes.CodecCompiler = require(KRF.shared.Networking.CodecCompiler)
local SchemaTestUtils = require(script.Parent.SchemaTestUtils)

local CodecTestUtils = {}

function CodecTestUtils.compile(definition: NetworkingTypes.SchemaDefinition): NetworkingTypes.CompiledCodec
	local schema: NetworkingTypes.CompiledSchema = SchemaTestUtils.compile(definition)
	local codec: NetworkingTypes.CompiledCodec?, reason: string? = Compiler.Compile(schema)
	expect(reason).toBeNil()
	assert(codec ~= nil, "Expected compiled codec")
	return codec
end

function CodecTestUtils.encode(codec: NetworkingTypes.CompiledCodec, value: any): buffer
	local size: number?, measureReason: string? = codec.Measure(value)
	expect(measureReason).toBeNil()
	assert(size ~= nil, "Expected exact measured size")
	local destination: buffer = buffer.create(size)
	local offset: number?, writeReason: string? = codec.Write(value, destination, 0)
	expect(writeReason).toBeNil()
	expect(offset).toBe(size)
	return destination
end

function CodecTestUtils.expectRoundTrip(codec: NetworkingTypes.CompiledCodec, value: any): ()
	local destination: buffer = CodecTestUtils.encode(codec, value)
	local decoded: any, offset: number?, reason: string? = codec.Read(destination, 0, buffer.len(destination))
	expect(reason).toBeNil()
	expect(offset).toBe(buffer.len(destination))
	expect(decoded).toEqual(value)
	expect(buffer.len(destination) <= codec.maxSizeBytes).toBe(true)
end

function CodecTestUtils.expectReadFailure(
	codec: NetworkingTypes.CompiledCodec,
	source: buffer,
	offset: number,
	limit: number,
	expectedReason: string
): ()
	local decoded: any = nil
	local nextOffset: number? = nil
	local reason: string? = nil
	local completed: boolean = pcall(function()
		decoded, nextOffset, reason = codec.Read(source, offset, limit)
	end)
	expect(completed).toBe(true)
	expect(decoded).toBeNil()
	expect(nextOffset).toBeNil()
	expect(reason).toBe(expectedReason)
end

-- Derive a collection prefix from the codec, avoiding a fixed private width.
function CodecTestUtils.collectionPrefix(codec: NetworkingTypes.CompiledCodec, emptyValue: any, count: number): buffer
	local empty: buffer = CodecTestUtils.encode(codec, emptyValue)
	local source: buffer = buffer.create(buffer.len(empty))
	local remaining: number = count
	for index: number = 0, buffer.len(source) - 1 do
		buffer.writeu8(source, index, remaining % 256)
		remaining = math.floor(remaining / 256)
	end
	assert(remaining == 0, "Test count must fit the codec's prefix")
	return source
end

return CodecTestUtils
