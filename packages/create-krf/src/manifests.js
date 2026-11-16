import { KRF_RUNTIME, ROBLOX_DEFINITIONS_URL, TOOLCHAIN, WALLY_REGISTRY } from "./compatibility.js";

export const ROJO_PROJECT_FILE = "default.project.json";
export const HYBRID_START_PROJECT_FILE = "start-place.project.json";

const DEFINITIONS_FILE = "build/globalTypes.d.luau";

const json = (value) => `${JSON.stringify(value, null, 2)}\n`;

export function projectScripts(config) {
	const buildProject = config.options.mode === "hybrid" ? HYBRID_START_PROJECT_FILE : ROJO_PROJECT_FILE;
	const sourcemap = `rojo sourcemap ${ROJO_PROJECT_FILE} --output sourcemap.json`;
	return {
		postinstall: "node scripts/setup.mjs",
		build: `rojo build ${buildProject} --output ${config.name}.rbxl`,
		format: "stylua src",
		check: "stylua --check src && selene src && npm run typecheck",
		typecheck: [
			sourcemap,
			`curl -sSfL --create-dirs -o ${DEFINITIONS_FILE} ${ROBLOX_DEFINITIONS_URL}`,
			`luau-lsp analyze --flag:LuauSolverV2=true --platform=roblox --no-strict-dm-types --definitions:@roblox=${DEFINITIONS_FILE} --sourcemap=sourcemap.json --ignore="Packages/**" src`,
		].join(" && "),
	};
}

export function packageManifest(config) {
	return json({
		name: config.name,
		version: "0.0.0",
		private: true,
		description: "A Roblox game built with KRF.",
		scripts: projectScripts(config),
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

function starterWorld() {
	return {
		Workspace: {
			$className: "Workspace",
			Baseplate: {
				$className: "Part",
				$properties: {
					Anchored: true,
					Locked: true,
					Size: [512, 16, 512],
					Position: [0, -8, 0],
					Color: [0.388, 0.372, 0.384],
					Material: "Slate",
					TopSurface: "Smooth",
					BottomSurface: "Smooth",
				},
			},
			SpawnLocation: {
				$className: "SpawnLocation",
				$properties: {
					Anchored: true,
					Size: [12, 1, 12],
					Position: [0, 0.5, 0],
					TopSurface: "Smooth",
					BottomSurface: "Smooth",
				},
			},
		},
	};
}

function rojoProject(name, tree) {
	return json({ name, tree: { $className: "DataModel", ...tree } });
}

export function rojoProjects(config) {
	if (config.options.mode === "full") {
		return new Map([[ROJO_PROJECT_FILE, rojoProject(config.name, { ...codeTree(), ...starterWorld() })]]);
	}

	return new Map([
		[ROJO_PROJECT_FILE, rojoProject(config.name, codeTree())],
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
