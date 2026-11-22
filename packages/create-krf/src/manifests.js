import { ASSET_SCRIPTS, DEFINITION_SCRIPTS, KRF_RUNTIME, TEST_PACKAGES } from "krf-tools";

import { ROBLOX_DEFINITIONS_URL, TOOLCHAIN, WALLY_REGISTRY } from "./compatibility.js";
import { TOOLS_DEPENDENCY } from "./tooling.js";

export const ROJO_PROJECT_FILE = "default.project.json";
export const HYBRID_START_PROJECT_FILE = "start-place.project.json";
export const WORLD_FOLDER = "world/Workspace";

const DEFINITIONS_FILE = "build/globalTypes.d.luau";

const json = (value) => `${JSON.stringify(value, null, 2)}\n`;

export function projectScripts(config) {
	const build =
		config.options.mode === "hybrid" ? `rojo build ${HYBRID_START_PROJECT_FILE} --output build/${config.name}.rbxl` : `rojo build ${ROJO_PROJECT_FILE} --output ${config.name}.rbxl`;
	const sourcemap = `rojo sourcemap ${ROJO_PROJECT_FILE} --output sourcemap.json`;
	return {
		postinstall: "node scripts/setup.mjs",
		dev: "krf-tools dev",
		build,
		test: "krf-tools test",
		"test:studio": "krf-tools test-studio",
		format: "stylua src tests",
		check: "stylua --check src tests && selene src tests && npm run typecheck",
		typecheck: [
			sourcemap,
			`curl -sSfL --create-dirs -o ${DEFINITIONS_FILE} ${ROBLOX_DEFINITIONS_URL}`,
			`luau-lsp analyze --flag:LuauSolverV2=true --platform=roblox --no-strict-dm-types --definitions:@roblox=${DEFINITIONS_FILE} --sourcemap=sourcemap.json --ignore="Packages/**" src`,
		].join(" && "),
		...ASSET_SCRIPTS,
		...DEFINITION_SCRIPTS,
	};
}

export function packageManifest(config) {
	return json({
		name: config.name,
		version: "0.0.0",
		private: true,
		description: "A Roblox game built with KRF.",
		scripts: projectScripts(config),
		devDependencies: TOOLS_DEPENDENCY,
	});
}

function codeTree() {
	return {
		ReplicatedStorage: {
			$className: "ReplicatedStorage",
			Packages: { $path: "Packages" },
			Shared: { $path: "src/shared" },
		},
		ServerScriptService: {
			$className: "ServerScriptService",
			Game: { $path: "src/server" },
		},
		StarterPlayer: {
			$className: "StarterPlayer",
			StarterPlayerScripts: {
				$className: "StarterPlayerScripts",
				Game: { $path: "src/client" },
			},
		},
	};
}

const IDENTITY = [1, 0, 0, 0, 1, 0, 0, 0, 1];

function starterWorld() {
	return {
		Workspace: {
			$className: "Workspace",
			Baseplate: {
				$className: "Part",
				$properties: {
					Anchored: true,
					BottomSurface: "Smooth",
					CFrame: [0, -8, 0, ...IDENTITY],
					Color: { Color3uint8: [99, 95, 98] },
					Locked: true,
					Material: "Slate",
					Size: [512, 16, 512],
					TopSurface: "Smooth",
				},
			},
			SpawnLocation: {
				$className: "SpawnLocation",
				$properties: {
					Anchored: true,
					BottomSurface: "Smooth",
					CFrame: [0, 0.5, 0, ...IDENTITY],
					Size: [12, 1, 12],
					TopSurface: "Smooth",
				},
			},
		},
	};
}

function capturedWorld() {
	return { Workspace: { $className: "Workspace", $ignoreUnknownInstances: true, $path: WORLD_FOLDER } };
}

const STUDIO_PROPERTIES_UNKNOWN_TO_ROJO = Object.freeze({
	Instance: ["ExplorerIconContent", "SerializedOverrides"],
	StarterPlayer: ["UseImprovedCharacterEvents"],
	Workspace: ["InputSinkEnabled", "NextGenerationPhysicsSolver", "ParticlesUseDynamicWind", "ReplicationFrequency", "ReplicationThroughput", "UseNewLuauTypeSolver"],
});

function syncbackRules() {
	const trees = [];
	const visit = (node, prefix) => {
		for (const [name, child] of Object.entries(node)) {
			if (name.startsWith("$")) continue;
			const tree = [...prefix, name];
			if (child.$path !== undefined) trees.push(tree.join("/"));
			else visit(child, tree);
		}
	};
	visit(codeTree(), []);
	return { ignoreTrees: [...trees, "Workspace/Terrain"], ignoreProperties: STUDIO_PROPERTIES_UNKNOWN_TO_ROJO };
}

function rojoProject(name, tree, rules) {
	return json({ name, tree: { $className: "DataModel", ...tree }, ...(rules === undefined ? {} : { syncbackRules: rules }) });
}

export function rojoProjects(config) {
	if (config.options.mode === "full") {
		return new Map([[ROJO_PROJECT_FILE, rojoProject(config.name, { ...codeTree(), ...capturedWorld() }, syncbackRules())]]);
	}

	return new Map([
		[ROJO_PROJECT_FILE, rojoProject(config.name, codeTree(), syncbackRules())],
		[HYBRID_START_PROJECT_FILE, rojoProject(config.name, { ...codeTree(), ...starterWorld() })],
	]);
}

export function rokitManifest() {
	const lines = [
		"[tools]",
		...Object.entries(TOOLCHAIN).map(([alias, tool]) => `${alias} = "${tool}"`),
		"",
	];
	return lines.join("\n");
}

export function wallyPackageName(projectName) {
	const scope = projectName.replace(/[^a-z0-9-]/g, "-");
	return `${scope}/${scope}`;
}

export function wallyManifest(config) {
	return [
		"[package]",
		`name = "${wallyPackageName(config.name)}"`,
		'version = "0.0.0"',
		`registry = "${WALLY_REGISTRY}"`,
		'realm = "shared"',
		"private = true",
		"",
		"[dependencies]",
		`KRF = "${KRF_RUNTIME.package}@=${KRF_RUNTIME.version}"`,
		"",
		"[dev-dependencies]",
		...Object.entries(TEST_PACKAGES).map(([alias, dependency]) => `${alias} = "${dependency}"`),
		"",
	].join("\n");
}

export function generatedManifests(config) {
	return new Map([
		["package.json", packageManifest(config)],
		...rojoProjects(config),
		["rokit.toml", rokitManifest()],
		["wally.toml", wallyManifest(config)],
	]);
}
