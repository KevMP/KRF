import packageJson from "../package.json" with { type: "json" };

export const CREATOR_VERSION = packageJson.version;

export const WALLY_REGISTRY = "https://github.com/UpliftGames/wally-index";

export const ROBLOX_DEFINITIONS_URL = "https://luau-lsp.pages.dev/type-definitions/globalTypes.None.d.luau";

export const ROKIT_VERSION = "1.2.0";

export const TOOLCHAIN = Object.freeze({
	rojo: "rojo-rbx/rojo@7.6.1",
	wally: "UpliftGames/wally@0.3.2",
	"wally-package-types": "JohnnyMorganz/wally-package-types@1.6.2",
	stylua: "JohnnyMorganz/StyLua@2.3.1",
	selene: "Kampfkarren/selene@0.30.0",
	"luau-lsp": "JohnnyMorganz/luau-lsp@1.70.1",
});
