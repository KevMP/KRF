import packageJson from "../package.json" with { type: "json" };

export const TOOLS_PACKAGE = packageJson.name;

export const TOOLS_VERSION = packageJson.version;

export const KRF_RUNTIME = Object.freeze({ package: "kevmp/krf", version: "0.2.0" });

export const SUPPORTED_KRF_VERSIONS = Object.freeze(["0.2.0"]);

export const TEST_PACKAGES = Object.freeze({
	Jest: "jsdotlua/jest@3.10.0",
	JestGlobals: "jsdotlua/jest-globals@3.10.0",
});
