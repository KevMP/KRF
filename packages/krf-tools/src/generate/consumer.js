import fs from "node:fs";
import path from "node:path";

import { KRF_RUNTIME, SUPPORTED_KRF_VERSIONS, TOOLS_PACKAGE, TOOLS_VERSION } from "../compatibility.js";
import { KrfToolError } from "../errors.js";
import { isIdentifier } from "./luau.js";

const INSTANCE_SUFFIX = /(\.server|\.client)?\.(luau|lua)$|\.model\.json$|\.json$|\.txt$|\.csv$|\.toml$|\.rbxmx?$/;
const DEFINITION_ID = /^\t{1,2}(?:id|key) = "([^"\\]*)",\r?$/m;

export function findProjectRoot(cwd) {
	for (let directory = path.resolve(cwd); ; directory = path.dirname(directory)) {
		if (fs.existsSync(path.join(directory, "package.json"))) {
			if (!fs.existsSync(path.join(directory, "wally.toml"))) {
				throw new KrfToolError("NotKrfProject", `${directory} has no wally.toml, so it is not a KRF project.`, {
					hint: "Run the generator through the project's npm scripts, such as npm run createAction.",
				});
			}
			return directory;
		}
		if (path.dirname(directory) === directory) {
			throw new KrfToolError("NotKrfProject", "No package.json found in this directory or its parents.", {
				hint: "Run the generator through the project's npm scripts, such as npm run createAction.",
			});
		}
	}
}

export function createConsumer(root) {
	const resolve = (relative) => path.join(root, ...relative.split("/"));

	const stat = (relative) => {
		try {
			return fs.lstatSync(resolve(relative));
		} catch (error) {
			if (error?.code === "ENOENT" || error?.code === "ENOTDIR") return undefined;
			throw error;
		}
	};

	const read = (relative) => (stat(relative)?.isFile() ? fs.readFileSync(resolve(relative), "utf8") : undefined);

	const readBytes = (relative) => (stat(relative)?.isFile() ? fs.readFileSync(resolve(relative)) : undefined);

	const list = (relative) => (stat(relative)?.isDirectory() ? fs.readdirSync(resolve(relative), { withFileTypes: true }) : []);

	function luauFiles(relative) {
		const found = [];
		for (const entry of list(relative)) {
			const child = `${relative}/${entry.name}`;
			if (entry.isDirectory()) found.push(...luauFiles(child));
			else if (entry.isFile() && /\.luau?$/.test(entry.name) && !/^init\./.test(entry.name)) found.push(child);
		}
		return found.sort();
	}

	return Object.freeze({ root, stat, read, readBytes, list, luauFiles });
}

export function readKrfDependency(consumer) {
	const manifest = consumer.read("wally.toml") ?? "";
	const dependency = /^\s*([^\s=#]+)\s*=\s*"kevmp\/krf@([^"]+)"/m.exec(manifest);
	if (!dependency) {
		throw new KrfToolError("KrfDependencyMissing", `wally.toml does not depend on ${KRF_RUNTIME.package}.`, {
			hint: `Add it under [dependencies], for example: KRF = "${KRF_RUNTIME.package}@=${KRF_RUNTIME.version}"`,
		});
	}

	const alias = dependency[1];
	if (!isIdentifier(alias)) {
		throw new KrfToolError("KrfAliasUnsupported", `The KRF dependency alias '${alias}' is not a Luau identifier.`, {
			hint: `Rename it in wally.toml, for example: KRF = "${KRF_RUNTIME.package}@=${KRF_RUNTIME.version}"`,
		});
	}

	const lock = consumer.read("wally.lock") ?? "";
	const locked = lock
		.split(/\[\[package\]\]/)
		.map((block) => ({ name: /^name = "([^"]+)"/m.exec(block)?.[1], version: /^version = "([^"]+)"/m.exec(block)?.[1] }))
		.find((entry) => entry.name === KRF_RUNTIME.package);
	const exact = /^=\s*(\d+\.\d+\.\d+)$/.exec(dependency[2].trim());
	const version = locked?.version ?? exact?.[1];

	if (version === undefined) {
		throw new KrfToolError("KrfVersionUnresolved", `wally.toml requests ${KRF_RUNTIME.package}@${dependency[2]}, but wally.lock does not say which version is installed.`, {
			hint: "Run npm install so Wally writes wally.lock, then run the generator again.",
		});
	}

	if (!SUPPORTED_KRF_VERSIONS.includes(version)) {
		throw new KrfToolError("KrfVersionUnsupported", `${TOOLS_PACKAGE} ${TOOLS_VERSION} generates definitions for ${KRF_RUNTIME.package} ${SUPPORTED_KRF_VERSIONS.join(", ")}; this project uses ${version}.`, {
			hint: `Install a ${TOOLS_PACKAGE} release that supports ${KRF_RUNTIME.package} ${version}: npm install --save-dev --save-exact ${TOOLS_PACKAGE}@<version>`,
		});
	}

	return { alias, version };
}

export function definitionId(source) {
	return DEFINITION_ID.exec(source)?.[1];
}

export function findDefinition(consumer, folders, id) {
	for (const folder of folders) {
		for (const file of consumer.luauFiles(folder)) {
			if (definitionId(consumer.read(file) ?? "") === id) return file;
		}
	}
	return undefined;
}

function instanceName(entry) {
	return entry.isDirectory() ? entry.name : entry.name.replace(INSTANCE_SUFFIX, "");
}

export function assertPathAvailable(consumer, target) {
	const segments = target.split("/");
	for (let index = 1; index < segments.length; index++) {
		const parent = segments.slice(0, index).join("/");
		const wanted = index === segments.length - 1 ? segments[index].replace(INSTANCE_SUFFIX, "") : segments[index];
		const exact = segments[index];

		for (const entry of consumer.list(parent)) {
			if (entry.name.startsWith(".") || /^init\./.test(entry.name) || /\.meta\.json$/.test(entry.name)) continue;
			if (instanceName(entry).toLowerCase() !== wanted.toLowerCase()) continue;
			const sameEntry = entry.name === exact && (index === segments.length - 1 ? entry.isFile() : entry.isDirectory());
			if (sameEntry) continue;

			throw new KrfToolError("NameConflict", `${parent}/${entry.name} already uses the name ${wanted}; ${segments.slice(0, index + 1).join("/")} would conflict with it.`, {
				hint: "Choose another --name or --id, or another --output path.",
			});
		}
	}
}
