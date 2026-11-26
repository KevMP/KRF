import { WORLD_SCRIPTS, BUILD_PLACES_SCRIPT, DEFINITION_SCRIPTS, DEPLOY_SCRIPTS, KRF_RUNTIME, TEST_PACKAGES } from "krf-tools";

import { ROBLOX_DEFINITIONS_URL, TOOLCHAIN, WALLY_REGISTRY } from "./compatibility.js";
import { TOOLS_DEPENDENCY } from "./tooling.js";

export const ROJO_PROJECT_FILE = "default.project.json";
export const HYBRID_START_PROJECT_FILE = "start-place.project.json";
export const WORLD_FOLDER = "world";

const DEFINITIONS_FILE = "build/globalTypes.d.luau";
const CREATE_BUILD_FOLDER = `node -e "require('node:fs').mkdirSync('build', { recursive: true })"`;

const json = (value) => `${JSON.stringify(value, null, 2)}\n`;

export function projectScripts(config) {
	const named = config.options.places !== undefined;
	const build = named ? BUILD_PLACES_SCRIPT
		: config.options.mode === "hybrid" ? `${CREATE_BUILD_FOLDER} && rojo build ${HYBRID_START_PROJECT_FILE} --output build/${config.name}.rbxl`
			: `rojo build ${ROJO_PROJECT_FILE} --output ${config.name}.rbxl`;
	const sourcemap = named ? "krf-tools sourcemap" : `rojo sourcemap ${ROJO_PROJECT_FILE} --output sourcemap.json`;
	return {
		postinstall: "node scripts/setup.mjs",
		dev: "krf-tools dev",
		build,
		test: "krf-tools test",
		"test:studio": "krf-tools test-studio",
		...(named ? { sourcemap } : {}),
		format: "stylua src tests",
		check: "stylua --check src tests && selene src tests && npm run typecheck",
		typecheck: [
			sourcemap,
			`curl -sSfL --create-dirs -o ${DEFINITIONS_FILE} ${ROBLOX_DEFINITIONS_URL}`,
			`luau-lsp analyze --flag:LuauSolverV2=true --platform=roblox --no-strict-dm-types --definitions:@roblox=${DEFINITIONS_FILE} --sourcemap=sourcemap.json --ignore="Packages/**" src`,
		].join(" && "),
		...WORLD_SCRIPTS,
		...DEPLOY_SCRIPTS,
		...DEFINITION_SCRIPTS,
	};
}

export function packageManifest(config) {
	const places = config.options.places;
	return json({
		name: config.name,
		version: "0.0.0",
		private: true,
		description: "A Roblox game built with KRF.",
		...(places === undefined ? {} : { krf: { startPlace: places[0] } }),
		scripts: projectScripts(config),
		devDependencies: TOOLS_DEPENDENCY,
	});
}

function codeTree(prefix = "") {
	return {
		ReplicatedStorage: {
			$className: "ReplicatedStorage",
			Packages: { $path: `${prefix}Packages` },
			Shared: { $path: `${prefix}src/shared` },
		},
		ServerScriptService: {
			$className: "ServerScriptService",
			Game: { $path: `${prefix}src/server` },
		},
		StarterPlayer: {
			$className: "StarterPlayer",
			StarterPlayerScripts: {
				$className: "StarterPlayerScripts",
				Game: { $path: `${prefix}src/client` },
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

export const CAPTURED_SERVICES = Object.freeze([
	"Workspace",
	"Lighting",
	"MaterialService",
	"ReplicatedFirst",
	"ReplicatedStorage",
	"ServerScriptService",
	"ServerStorage",
	"StarterGui",
	"StarterPack",
	"StarterPlayer/StarterPlayerScripts",
	"StarterPlayer/StarterCharacterScripts",
	"SoundService",
	"Teams",
	"TextChatService",
]);

function capturedWorld(world = WORLD_FOLDER, prefix = "") {
	const code = codeTree(prefix);
	const tree = {};
	for (const service of CAPTURED_SERVICES) {
		const names = service.split("/");
		let node = tree;
		let source = code;
		for (const name of names.slice(0, -1)) {
			node = node[name] ??= { $className: name };
			source = source?.[name];
		}
		const name = names.at(-1);
		const children = Object.fromEntries(Object.entries(source?.[name] ?? {}).filter(([key]) => !key.startsWith("$")));
		node[name] = { $className: name, $ignoreUnknownInstances: true, $path: `${prefix}${world}/${service}`, ...children };
	}
	return tree;
}

const STUDIO_PROPERTIES_UNKNOWN_TO_ROJO = Object.freeze({
	Instance: ["ExplorerIconContent", "SerializedOverrides"],
	Lighting: ["LightAttenuationMode"],
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
		const places = config.options.places;
		if (places !== undefined) {
			return new Map(places.map((name) => {
				const tree = capturedWorld(`${WORLD_FOLDER}/${name}`, "../");
				return [namedRojoProject(name), rojoProject(`${config.name}-${name}`, tree, syncbackRules())];
			}));
		}
		return new Map([[ROJO_PROJECT_FILE, rojoProject(config.name, capturedWorld(), syncbackRules())]]);
	}

	return new Map([
		[ROJO_PROJECT_FILE, rojoProject(config.name, codeTree(), syncbackRules())],
		[HYBRID_START_PROJECT_FILE, rojoProject(config.name, { ...codeTree(), ...starterWorld() })],
	]);
}

function namedRojoProject(name) {
	return `places/${name}.project.json`;
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
