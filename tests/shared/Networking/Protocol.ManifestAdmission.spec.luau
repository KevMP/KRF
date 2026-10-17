--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Compiler: SharedNetworkingTypes.ManifestCompiler = require(KRF.shared.Networking.ManifestCompiler)
local Codecs: SharedNetworkingTypes.CodecCompiler = require(KRF.shared.Networking.CodecCompiler)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ProtocolTestUtils)

local originalCompile: typeof(Codecs.Compile) = Codecs.Compile
afterEach(function()
	Codecs.Compile = originalCompile
end)

for _, value: any in { false, "manifest", {}, { version = 1, domains = {}, [1] = true } } do
	it("rejects malformed top-level manifest metadata without throwing", function()
		local runtime: SharedNetworkingTypes.ClientProtocol?, reason: string? = Compiler.Reconstruct(value)
		expect(runtime).toBeNil()
		expect(reason).toBe("MalformedBootstrap")
	end)
end

type AdmissionCase = { name: string, mutate: (any) -> () }
local cases: { AdmissionCase } = {
	{
		name = "sparse domain catalog",
		mutate = function(manifest: any)
			manifest.domains[3] = manifest.domains[2]
			manifest.domains[2] = nil
		end,
	},
	{
		name = "non-table domain",
		mutate = function(manifest: any)
			manifest.domains[1] = false
		end,
	},
	{
		name = "empty domain identity",
		mutate = function(manifest: any)
			manifest.domains[1].id = ""
		end,
	},
	{
		name = "non-numeric domain code",
		mutate = function(manifest: any)
			manifest.domains[1].code = "0"
		end,
	},
	{
		name = "sparse event catalog",
		mutate = function(manifest: any)
			manifest.domains[1].events[2] = manifest.domains[1].events[1]
			manifest.domains[1].events[1] = nil
		end,
	},
	{
		name = "unexpected event callback",
		mutate = function(manifest: any)
			manifest.domains[1].events[1].observe = function() end
		end,
	},
	{
		name = "empty event identity",
		mutate = function(manifest: any)
			manifest.domains[1].events[1].id = ""
		end,
	},
	{
		name = "non-numeric event code",
		mutate = function(manifest: any)
			manifest.domains[1].events[1].code = "0"
		end,
	},
}
for _, testCase: AdmissionCase in cases do
	it("rejects " .. testCase.name .. " without publishing a partially compiled runtime", function()
		local manifest: SharedNetworkingTypes.ProtocolManifest = TestUtils.manifest()
		testCase.mutate(manifest)
		local runtime: SharedNetworkingTypes.ClientProtocol?, reason: string? = Compiler.Reconstruct(manifest)
		expect(runtime).toBeNil()
		expect(reason).toBe("MalformedBootstrap")
	end)
end

for _, providedReason: boolean in { true, false } do
	it("fails client reconstruction when runtime codec compilation rejects a valid semantic schema", function()
		Codecs.Compile = function(
			_schema: SharedNetworkingTypes.CompiledSchema
		): (SharedNetworkingTypes.CompiledCodec?, string?)
			return nil, if providedReason then "UnsupportedSchema" else nil
		end
		local runtime: SharedNetworkingTypes.ClientProtocol?, reason: string? =
			Compiler.Reconstruct(TestUtils.manifest())
		expect(runtime).toBeNil()
		expect(reason).toBe("UnsupportedSchema")
	end)
end
