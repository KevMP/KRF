import { ExitCode, KrfToolError } from "../errors.js";
import {
	ACTION_INPUT_POLICIES_FOLDER,
	ACTION_REQUESTS_FOLDER,
	BUILT_IN_CONTROLLER_KEYS,
	CATALOGS,
	KEYBINDS_FILE,
	KINDS,
	LOADOUT_FILE,
	REQUIRE_DESCENDANTS_FILE,
	STARTUP_FILE,
} from "./catalogs.js";
import { assertPathAvailable, definitionId, findDefinition } from "./consumer.js";
import { actionPolicyEntry, actionRequestEntry, mapEntryLines, needsInputPolicy, renderDefinition, renderLoader, renderMapModule } from "./modules.js";
import { addCatalog, readStartup, startupLines, wiringOf } from "./startup.js";

const CATALOG_LOADER = /\brequireDescendants\(script\)/;
const MAP_LOADER = /\bmergeDescendants\(script\)/;

const isInside = (file, folder) => folder !== undefined && file.startsWith(`${folder}/`);

function loaderState(consumer, folder, pattern = CATALOG_LOADER) {
	const source = consumer.read(`${folder}/init.luau`);
	if (source !== undefined) return pattern.test(source) ? "recognized" : "custom";
	return consumer.list(folder).some((entry) => /^init\./.test(entry.name)) ? "custom" : "missing";
}

function catalogFolders(startup) {
	return new Map(
		KINDS.map((kind) => {
			const wiring = wiringOf(startup, CATALOGS[kind].field);
			return [kind, { wiring, folder: wiring.folder ?? CATALOGS[kind].defaultFolder }];
		}),
	);
}

function definedIds(consumer, folder) {
	return new Set(consumer.luauFiles(folder).map((file) => definitionId(consumer.read(file) ?? "")));
}

function readStartupOf(consumer) {
	const source = consumer.read(STARTUP_FILE);
	return source === undefined ? undefined : readStartup(source);
}

function matchesIn(consumer, folder, pattern) {
	const found = new Set();
	for (const file of consumer.luauFiles(folder)) {
		for (const match of (consumer.read(file) ?? "").matchAll(pattern)) found.add(match[1]);
	}
	return found;
}

export function projectCatalog(consumer) {
	const folders = catalogFolders(readStartupOf(consumer));
	const folder = (kind) => folders.get(kind).folder;
	const ids = (kind) => [...definedIds(consumer, folder(kind))].filter(Boolean).sort();

	const locks = new Set();
	for (const list of matchesIn(consumer, folder("action"), /\blocks = \{([^}]*)\}/g)) {
		for (const lock of list.matchAll(/"([^"]+)"/g)) locks.add(lock[1]);
	}

	const properties = new Set([
		...matchesIn(consumer, folder("tag"), /\b([A-Za-z_][A-Za-z0-9_]*) = \{ (?:set|add|multiply|min|max) = /g),
		...matchesIn(consumer, folder("resource"), /\bpropertyName = "([^"]+)"/g),
		...matchesIn(consumer, folder("action"), /\bmultiplierProperty = "([^"]+)"/g),
	]);

	return Object.freeze({
		tag: ids("tag"),
		resource: ids("resource"),
		action: ids("action"),
		controller: [...BUILT_IN_CONTROLLER_KEYS, ...ids("controller")],
		lock: [...locks].sort(),
		property: [...properties].sort(),
	});
}

function referenceWarnings(consumer, request, folders) {
	const warnings = [];
	const missing = (kind, ids, extra = []) => {
		const folder = folders.get(kind).folder;
		const defined = definedIds(consumer, folder);
		for (const id of ids) {
			if (!defined.has(id) && !extra.includes(id)) {
				warnings.push(`${CATALOGS[kind].label} '${id}' is not defined in ${folder}; KRF rejects startup until it is.`);
			}
		}
	};

	if (request.kind === "action") {
		const { options } = request;
		missing("tag", [...new Set([...options.requiredTags, ...options.blockedTags, ...options.activeTags.map((entry) => entry.id), ...options.appliedTags.map((entry) => entry.id)])]);
		missing("resource", [...new Set([...options.requirements.map((entry) => entry.resource), ...options.costs.map((entry) => entry.resource)])]);
		missing("action", options.interruptibleBy, [request.id]);
	}
	if (request.kind === "controller") missing("controller", request.options.dependsOn, BUILT_IN_CONTROLLER_KEYS);
	return warnings;
}

function nextSteps(request, file) {
	const { id, options } = request;
	switch (request.kind) {
		case "action":
			return [
				...(options.requestable
					? [`Put ${id} in an ability slot with Loadout.Equip("AbilitySlot1", "${id}") in ${LOADOUT_FILE}, or add a slot for it in ${KEYBINDS_FILE}.`]
					: []),
				...(options.requestable && (options.startFields.length > 0 || (options.recipe === "held" && options.stopFields.length > 0))
					? [`Return the parameters input sends from the producers in ${[ACTION_INPUT_POLICIES_FOLDER, ...request.namespace, `${request.name}.luau`].join("/")}.`]
					: []),
				...(options.autoGrant ? [] : [`${id} is not auto-granted. Grant it with ActionController:SetGrants, or set autoGrant = true in ${file}.`]),
			];
		case "controller":
			return [`Get it on the server with actor:GetController("${id}").`];
		case "command":
			return [
				options.authorize === "deny"
					? `${id} rejects every request until you implement authorize and handle in ${file}.`
					: `${id} rejects every authorized request until you implement handle in ${file}.`,
			];
		case "hint":
			return options.direction === "ClientToServer"
				? [options.authorize === "deny" ? `${id} rejects every client send until you implement authorize and receive in ${file}.` : `Implement receive in ${file}.`]
				: [];
		case "domain":
			return [
				`Return the Actor's current state from snapshot in ${file}.`,
				...(options.observe ? [`Call onCommitted from observe when the state or its events change, and return a function that stops observing.`] : []),
			];
		default:
			return [];
	}
}

function findMapEntry(consumer, folder, key) {
	const escaped = key.replace(/\./g, "\\.");
	const pattern = new RegExp(`^\\t(?:${escaped}|\\["${escaped}"\\]) = `, "m");
	return consumer.luauFiles(folder).find((file) => pattern.test(consumer.read(file) ?? ""));
}

function wireRequest(consumer, request, plan, alias) {
	const targets = [
		{ folder: ACTION_REQUESTS_FOLDER, type: "ActionRequestSchemas", value: actionRequestEntry(request.options) },
		...(needsInputPolicy(request.options) ? [{ folder: ACTION_INPUT_POLICIES_FOLDER, type: "ActionInputPolicies", value: actionPolicyEntry(request.options) }] : []),
	];

	for (const target of targets) {
		const file = [target.folder, ...request.namespace, `${request.name}.luau`].join("/");
		const entry = mapEntryLines(request.id, target.value);
		const declared = findMapEntry(consumer, target.folder, request.id);

		if (declared !== undefined) {
			plan.warnings.push(`${declared} already declares ${request.id}; it was left unchanged.`);
		} else if (plan.status !== "created") {
			plan.manual.push({ file, instruction: `Once ${request.id} loads, create this module returning its ${target.type} entry.`, lines: entry });
		} else if (loaderState(consumer, target.folder, MAP_LOADER) !== "recognized") {
			plan.manual.push({ file: target.folder, instruction: `Add this entry to the ${target.type} your project passes to KRF.`, lines: entry });
		} else {
			assertPathAvailable(consumer, file);
			if (consumer.stat(file) !== undefined) {
				throw new KrfToolError("NameConflict", `${file} already exists but does not declare ${request.id}.`, { hint: "Rename that module or choose another --name. Nothing was written." });
			}
			plan.changes.push({ kind: "create", path: file, contents: renderMapModule(request.name, target.type, entry, alias) });
		}
	}
}

function wireCatalog(consumer, request, own, startup, alias, plan) {
	const catalog = CATALOGS[request.kind];
	const loader = loaderState(consumer, own.folder);

	if (own.wiring.state === "wired") {
		if (loader !== "recognized") {
			plan.manual.push({ file: `${own.folder}/init.luau`, instruction: `Return ${plan.file} from this loader with the other ${catalog.field}.`, lines: [] });
		}
		return;
	}

	if (own.wiring.state === "custom") {
		plan.manual.push({ file: STARTUP_FILE, instruction: `Include ${plan.file} in the ${catalog.field} passed to KRF.Server.Init.`, lines: [] });
		return;
	}

	if (loader === "missing" && consumer.stat(REQUIRE_DESCENDANTS_FILE)?.isFile()) {
		plan.changes.push({ kind: "create", path: `${own.folder}/init.luau`, contents: renderLoader(request.kind, alias) });
	} else if (loader !== "recognized") {
		plan.manual.push({
			file: `${own.folder}/init.luau`,
			instruction: `Make this folder's loader return every ${catalog.label} module beneath it, including ${plan.file}.`,
			lines: [],
		});
	}

	const edited = addCatalog(startup, catalog);
	if (edited !== undefined) {
		plan.changes.push({ kind: "edit", path: STARTUP_FILE, before: startup.source, after: edited });
	} else {
		const lines = startupLines(catalog);
		plan.manual.push({
			file: STARTUP_FILE,
			instruction: `Require the ${catalog.folder} loader with the other requires and pass it to KRF.Server.Init as ${catalog.field}.`,
			lines: [lines.require, lines.field],
		});
	}
}

export function planGeneration(consumer, request, alias) {
	const catalog = CATALOGS[request.kind];
	const startupSource = consumer.read(STARTUP_FILE);
	const startup = startupSource === undefined ? undefined : readStartup(startupSource);
	const folders = catalogFolders(startup);
	const own = folders.get(request.kind);
	const file = request.output ?? [own.folder, ...request.namespace, `${request.name}.luau`].join("/");
	const plan = { kind: request.kind, name: request.name, id: request.id, file, status: "created", changes: [], manual: [], next: [], warnings: [] };

	const parent = file.slice(0, file.lastIndexOf("/"));
	const base = file.slice(file.lastIndexOf("/") + 1);
	if (consumer.list(parent).some((entry) => entry.name === base && entry.isFile())) {
		return { ...plan, status: "already-exists" };
	}

	assertPathAvailable(consumer, file);
	for (const kind of KINDS) {
		if (kind !== request.kind && isInside(file, folders.get(kind).folder)) {
			throw new KrfToolError("OutputInOtherCatalog", `${file} is inside ${folders.get(kind).folder}, which holds ${CATALOGS[kind].field}.`, {
				hint: `Put ${catalog.field} under ${own.folder}.`,
				exitCode: ExitCode.usage,
			});
		}
	}

	const duplicate = findDefinition(consumer, [...new Set([own.folder, catalog.defaultFolder])], request.id);
	if (duplicate) {
		throw new KrfToolError("DuplicateId", `${duplicate} already defines the ${catalog.label} '${request.id}'.`, {
			hint: "Choose another --name or --id. Nothing was written.",
		});
	}

	plan.changes.push({ kind: "create", path: file, contents: renderDefinition(request, alias) });
	plan.warnings.push(...referenceWarnings(consumer, request, folders));

	if (isInside(file, own.folder)) {
		wireCatalog(consumer, request, own, startup, alias, plan);
		plan.status = plan.manual.length === 0 ? "created" : "manual-wiring-required";
	} else {
		plan.status = "created-not-loaded";
		plan.next.push(`Nothing loads ${file}. ${STARTUP_FILE} loads ${catalog.field} from ${own.folder}; move the module under that folder.`);
	}

	if (request.kind === "action" && request.options.requestable) {
		wireRequest(consumer, request, plan, alias);
		if (plan.status === "created" && plan.manual.length > 0) plan.status = "manual-wiring-required";
	}

	plan.next.push(...nextSteps(request, file));
	return plan;
}
