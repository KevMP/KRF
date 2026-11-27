--!strict
local MAX_ASSET_ID: string = "9223372036854775807"

local ASSET_PATTERNS: { string } = table.freeze({
	"^rbxassetid://(%d+)$",
	"^https?://www%.roblox%.com/asset/?%?id=(%d+)$",
	"^https?://roblox%.com/asset/?%?id=(%d+)$",
})

local ContentId = {}

function ContentId.Normalize(value: unknown): string?
	if type(value) ~= "string" then
		return nil
	end

	local trimmed: string = string.lower(string.match(value, "^%s*(.-)%s*$") :: string)

	for _, pattern: string in ASSET_PATTERNS do
		local digits: string? = string.match(trimmed, pattern)

		if digits ~= nil then
			local canonical: string = string.gsub(digits, "^0+", "")

			if
				canonical == ""
				or #canonical > #MAX_ASSET_ID
				or #canonical == #MAX_ASSET_ID and canonical > MAX_ASSET_ID
			then
				return nil
			end

			return "rbxassetid://" .. canonical
		end
	end

	return nil
end

return table.freeze(ContentId)
