--!strict
local ContentProvider = game:GetService("ContentProvider")
local Types = require(script.Parent.Parent.types)

local NativeContentPort: Types.ContentPreloadPort = table.freeze({
	PreloadAsync = function(
		targets: { Instance },
		record: (contentId: string, status: Enum.AssetFetchStatus) -> ()
	): ()
		ContentProvider:PreloadAsync(targets, record :: any)
	end,
	Report = function(reason: string): ()
		warn("[Assets] reason=" .. reason)
	end,
})

return NativeContentPort
