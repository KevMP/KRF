import * as clack from "@clack/prompts";

import { ExitCode, KrfToolError } from "../errors.js";
import { CATALOGS } from "./catalogs.js";
import { isIdentifier } from "./luau.js";
import { ENTRY_PROBLEMS, OPTION_DEFAULTS, nameProblem } from "./request.js";

const RECIPE_HOOKS = { instant: "onStart", channel: "onUpdate", held: "onStopRequested", toggle: "onStopRequested" };
const KNOWN_SHOWN = 12;

const HOOKS = [
	{ value: "onCanStart", label: "onCanStart", hint: "can refuse to start the Action" },
	{ value: "onStart", label: "onStart", hint: "runs when the Action starts" },
	{ value: "onStopRequested", label: "onStopRequested", hint: "runs when a Stop is requested" },
	{ value: "onUpdate", label: "onUpdate", hint: "runs every frame while the Action is active" },
	{ value: "onEnd", label: "onEnd", hint: "runs when the Action ends" },
	{ value: "onInterrupt", label: "onInterrupt", hint: "runs when the Action is interrupted" },
	{ value: "canBeInterruptedBy", label: "canBeInterruptedBy", hint: "decides case by case whether interruptibleBy applies" },
];

const VISIBILITY = [
	{ value: "ServerOnly", label: "ServerOnly", hint: "hidden from clients" },
	{ value: "ClientVisible", label: "ClientVisible", hint: "replicated to clients" },
];

const NETWORK_TARGET = [
	{ value: "Actor", label: "Actor", hint: "about one Actor" },
	{ value: "None", label: "None", hint: "not tied to an Actor" },
];

const AUTHORIZATION = [
	{ value: "deny", label: "deny", hint: "an authorize stub that rejects every send until you write the check" },
	{ value: "OwnerActor", label: "OwnerActor", hint: "only the player who owns the target Actor" },
	{ value: "AnyReadyClient", label: "AnyReadyClient", hint: "any connected player" },
];

const NUMERIC_SOURCE = [
	{ value: "value", label: "value", hint: "a fixed number" },
	{ value: "property", label: "propertyName", hint: "read from a property that Tags can modify" },
];

const TYPES = [
	{ value: "Boolean", label: "Boolean", hint: "true or false" },
	{ value: "U8", label: "U8", hint: "whole number, 0 to 255" },
	{ value: "U16", label: "U16", hint: "whole number, 0 to 65,535" },
	{ value: "U32", label: "U32", hint: "whole number, 0 to about 4 billion" },
	{ value: "I8", label: "I8", hint: "whole number, -128 to 127" },
	{ value: "I16", label: "I16", hint: "whole number, -32,768 to 32,767" },
	{ value: "I32", label: "I32", hint: "whole number, about -2 billion to 2 billion" },
	{ value: "F32", label: "F32", hint: "decimal number" },
	{ value: "F64", label: "F64", hint: "high-precision decimal number" },
	{ value: "String", label: "String", hint: "text" },
	{ value: "Enum", label: "Enum", hint: "one of a fixed set of names" },
	{ value: "Array", label: "Array", hint: "a list" },
	{ value: "Map", label: "Map", hint: "a lookup table" },
];

const isBlank = (value) => (value ?? "").trim() === "";

function numberProblem(value, { min, max, above, integer } = {}) {
	const parsed = Number(value);
	if (isBlank(value) || !Number.isFinite(parsed)) return "Enter a number.";
	if (integer && !Number.isInteger(parsed)) return "Enter a whole number.";
	if (above !== undefined && parsed <= above) return `Enter a number greater than ${above}.`;
	if (min !== undefined && parsed < min) return `Enter a number of at least ${min}.`;
	if (max !== undefined && parsed > max) return `Enter a number of at most ${max}.`;
	return undefined;
}

const optional = (problem) => (value) => (isBlank(value) ? undefined : problem(value));

function idListProblem(value) {
	for (const id of value.split(",").map((part) => part.trim())) {
		const problem = ENTRY_PROBLEMS.id(id);
		if (problem) return `'${id}': ${problem}`;
	}
	return undefined;
}

function costProblem(value) {
	const match = /^\s*([0-9.]+)\s*(%?)\s*$/.exec(value ?? "");
	return match && Number(match[1]) > 0 ? undefined : "Enter an amount such as 10, or a percent of the Resource's range such as 25%.";
}

function knownText(known) {
	if (known.length === 0) return "";
	const shown = known.slice(0, KNOWN_SHOWN).join(", ");
	return `; this project has ${shown}${known.length > KNOWN_SHOWN ? ", ..." : ""}`;
}

const percent = (value) => String(Number(value) / 100);

function createAsker(prompts) {
	const ask = async (prompt) => {
		const value = await prompt;
		if (prompts.isCancel(value)) throw new KrfToolError("Cancelled", "Cancelled. No files were written.", { exitCode: ExitCode.cancelled });
		return value;
	};

	const asker = {
		text: async (message, options = {}) => (await ask(prompts.text({ message, ...options }))).trim(),
		confirm: (message, initialValue = false) => ask(prompts.confirm({ message, initialValue })),
		select: (message, options, initialValue) => ask(prompts.select({ message, options, initialValue })),
		multiselect: (message, options) => ask(prompts.multiselect({ message, options, required: false })),
		number: (message, constraints, initialValue) => asker.text(message, { initialValue, validate: (value) => numberProblem(value, constraints) }),
		optionalNumber: (message, constraints) => asker.text(message, { validate: optional((value) => numberProblem(value, constraints)) }),

		async ids(field, description, known) {
			const answer = await asker.text(`${field} (${description}; comma separated, blank for none${knownText(known)})`, { validate: optional(idListProblem) });
			return answer === "" ? [] : [...new Set(answer.split(",").map((id) => id.trim()))];
		},

		async type(path, description) {
			const kind = await asker.select(description === undefined ? `${path} type` : `${path} type (${description})`, TYPES);
			switch (kind) {
				case "String":
					return `String(${await asker.number(`${path} maxBytes (longest text allowed, in bytes)`, { above: 0, integer: true }, "32")})`;
				case "Enum": {
					const names = await asker.text(`${path} values (allowed names, comma separated)`, {
						placeholder: "Fire, Ice",
						validate: (value) => ENTRY_PROBLEMS.field(`Value:Enum(${(value ?? "").split(",").map((name) => name.trim()).join("|")})`),
					});
					return `Enum(${names.split(",").map((name) => name.trim()).join("|")})`;
				}
				case "Array": {
					const maxLength = await asker.number(`${path} maxLength (most items the list holds)`, { above: 0, integer: true }, "8");
					return `Array(${await asker.type(`${path}[]`, `each item in ${path}`)},${maxLength})`;
				}
				case "Map": {
					const maxEntries = await asker.number(`${path} maxEntries (most entries the lookup table holds)`, { above: 0, integer: true }, "8");
					const key = await asker.type(`${path}[key]`, `each key in ${path}`);
					const value = await asker.type(`${path}[value]`, `each value in ${path}`);
					return `Map(${key},${value},${maxEntries})`;
				}
				default:
					return kind;
			}
		},

		async fields(path, description) {
			const fields = [];
			for (;;) {
				const taken = fields.map((field) => field.split(":")[0]);
				const name = await asker.text(`${path} field name (${description}; blank to finish)`, {
					validate: optional((value) =>
						!isIdentifier(value.trim()) ? "Use letters, digits and '_', starting with a letter." : taken.includes(value.trim()) ? `${value.trim()} is already a field.` : undefined,
					),
				});
				if (name === "") return fields;
				const type = await asker.type(`${path}.${name}`);
				fields.push((await asker.confirm(`${path}.${name} optional (the field can be left out)`)) ? `${name}:Optional(${type})` : `${name}:${type}`);
			}
		},

		async numericSource(field, description, { initialValue, allowNegative, allowNone, known = [] }) {
			const from = await asker.select(`${field} (${description})`, allowNone ? [{ value: "none", label: "none" }, ...NUMERIC_SOURCE] : NUMERIC_SOURCE);
			if (from === "none") return undefined;
			const constraints = allowNegative ? {} : { min: 0 };
			if (from === "value") return asker.number(`${field}.value`, constraints, initialValue);
			return asker.text(`${field}.propertyName (a registered Property ID${knownText(known)})`, { placeholder: "MaxStamina", validate: (value) => ENTRY_PROBLEMS.id((value ?? "").trim()) });
		},
	};
	return asker;
}

async function askTagApplications(asker, known, field, description, durationNote) {
	const tags = await asker.ids(field, description, known.tag);
	const entries = [];
	for (const tag of tags) {
		const seconds = await asker.optionalNumber(`${field}.${tag}.duration (seconds; blank: ${durationNote})`, { above: 0 });
		entries.push(seconds === "" ? tag : `${tag}:${seconds}`);
	}
	return entries;
}

async function askRequirements(asker, known) {
	const resources = await asker.ids("resourceRequirements", "Resources that must be at a certain level for the Action to start", known.resource);
	const entries = [];
	for (const resource of resources) {
		const path = `resourceRequirements.${resource}`;
		const parts = [];
		const min = await asker.optionalNumber(`${path}.min (lowest amount allowed; blank to skip)`, {});
		if (min !== "") parts.push(`min=${min}`);
		const max = await asker.optionalNumber(`${path}.max (highest amount allowed; blank to skip)`, min === "" ? {} : { min: Number(min) });
		if (max !== "") parts.push(`max=${max}`);
		const minPercent = await asker.optionalNumber(`${path}.minPercent (lowest percent of the Resource's maximum, 0-100; blank to skip)`, { min: 0, max: 100 });
		if (minPercent !== "") parts.push(`minPercent=${percent(minPercent)}`);
		const maxPercent = await asker.optionalNumber(`${path}.maxPercent (highest percent of the Resource's maximum, 0-100; blank to skip)`, {
			min: minPercent === "" ? 0 : Number(minPercent),
			max: 100,
		});
		if (maxPercent !== "") parts.push(`maxPercent=${percent(maxPercent)}`);
		if (parts.length > 0) entries.push(`${resource}:${parts.join(",")}`);
	}
	return entries;
}

async function askCosts(asker, known) {
	const resources = await asker.ids("costs", "Resources spent when the Action starts", known.resource);
	const entries = [];
	for (const resource of resources) {
		const cost = await asker.text(`costs.${resource} (an amount such as 10, or a percent of the Resource's range such as 25%)`, { validate: costProblem });
		const isPercent = cost.endsWith("%");
		const value = isPercent ? percent(cost.slice(0, -1).trim()) : cost;
		const property = await asker.text(`costs.${resource}.multiplierProperty (a Property whose value multiplies the cost; blank for none${knownText(known.property)})`, {
			validate: optional((text) => ENTRY_PROBLEMS.id(text.trim())),
		});
		if (property !== "") entries.push(`${resource}:${isPercent ? "percent" : "amount"}=${value},multiplierProperty=${property}`);
		else entries.push(isPercent ? `${resource}:percent=${value}` : `${resource}=${value}`);
	}
	return entries;
}

async function askPropertyModifiers(asker, known) {
	const properties = await asker.ids("properties", "properties the Tag modifies while active", known.property);
	const entries = [];
	for (const property of properties) {
		const path = `properties.${property}`;
		const set = await asker.optionalNumber(`${path}.set (replace the property with this value; blank to adjust the property instead)`, {});
		if (set !== "") {
			entries.push(`${property}:set=${set}`);
			continue;
		}
		const parts = [];
		for (const [operation, description] of [
			["add", "amount added"],
			["multiply", "multiplier"],
			["min", "lowest value allowed"],
			["max", "highest value allowed"],
		]) {
			const value = await asker.optionalNumber(`${path}.${operation} (${description}; blank to skip)`, {});
			if (value !== "") parts.push(`${operation}=${value}`);
		}
		if (parts.length > 0) entries.push(`${property}:${parts.join(",")}`);
	}
	return entries;
}

const FLOWS = {
	async action(asker, need, set, known, options) {
		if (need("recipe")) {
			set(
				"recipe",
				await asker.select("recipe (which lifecycle hook ends the Action)", [
					{ value: "instant", label: "instant", hint: "onStart ends the Action right away" },
					{ value: "channel", label: "channel", hint: "onUpdate ends the Action after a duration" },
					{ value: "held", label: "held", hint: "onStopRequested ends the Action when the player releases its input" },
					{ value: "toggle", label: "toggle", hint: "onStopRequested ends the Action when the player presses its input again" },
				]),
			);
		}
		if (need("duration") && options.recipe === "channel") set("duration", await asker.number("duration (seconds the Action runs)", { above: 0 }, "1"));
		if (need("autoGrant")) set("autoGrant", await asker.confirm("autoGrant (every Actor can use the Action without a grant)"));
		if (need("requiredTags")) set("requiredTags", await asker.ids("requiredTags", "Tags the Actor must have for the Action to start", known.tag));
		if (need("blockedTags")) set("blockedTags", await asker.ids("blockedTags", "Tags that stop the Action from starting", known.tag));
		if (need("activeTags")) set("activeTags", await askTagApplications(asker, known, "activeTags", "Tags applied while the Action runs, removed when the Action ends", "until the Action ends"));
		if (need("appliedTags")) set("appliedTags", await askTagApplications(asker, known, "appliedTags", "Tags applied when the Action starts", "the Tag's default duration"));
		if (need("requirements")) set("requirements", await askRequirements(asker, known));
		if (need("costs")) set("costs", await askCosts(asker, known));
		if (need("locks")) set("locks", await asker.ids("locks", "lock names held while the Action runs; Actions that share a lock never run at the same time", known.lock));
		if (need("interruptibleBy") && options.locks.length > 0) {
			set("interruptibleBy", await asker.ids("interruptibleBy", "Actions allowed to end this Action and take over its locks", known.action));
		}
		if (need("hooks")) {
			const available = HOOKS.filter((hook) => hook.value !== RECIPE_HOOKS[options.recipe] && (hook.value !== "canBeInterruptedBy" || options.interruptibleBy.length > 0));
			set("hooks", await asker.multiselect("hooks (extra lifecycle hook stubs; space to select, enter to confirm)", available));
		}
		if (need("requestable")) set("requestable", await asker.confirm("requestable (players can request the Action from the client)"));
		if (need("visibility")) {
			set("visibility", await asker.select("visibility (who can see the Action)", VISIBILITY, options.requestable ? "ClientVisible" : "ServerOnly"));
		}
		if (!options.requestable) return;

		if (need("startFields")) set("startFields", await asker.fields("start", "parameters the client sends when requesting the Action"));
		if (need("clientStop") && options.recipe === "channel") {
			set("clientStop", await asker.confirm("stop (the client can request a Stop; a Stop does not end the Action by itself, onStopRequested decides what happens)"));
		}
		if (need("stopFields") && (options.recipe === "held" || options.recipe === "toggle" || options.clientStop)) {
			set("stopFields", await asker.fields("stop.parameters", "parameters the client sends with a Stop"));
		}
		if (need("allowInputInterrupt") && options.recipe !== "held") {
			set("allowInputInterrupt", await asker.confirm("allowInputInterrupt (client input can interrupt the Action)"));
		}
		if (need("onDisconnect") && options.recipe !== "held") {
			set(
				"onDisconnect",
				await asker.select(
					"onDisconnect (what happens to the Action when the requesting player leaves)",
					[
						{ value: "Keep", label: "Keep", hint: "the Action keeps running" },
						{ value: "Interrupt", label: "Interrupt", hint: "the Action is interrupted" },
					],
					"Keep",
				),
			);
		}
	},

	async tag(asker, need, set, known, options) {
		if (need("visibility")) set("visibility", await asker.select("visibility (who can see the Tag)", VISIBILITY, OPTION_DEFAULTS.tag.visibility));
		if (need("duplicateBehavior")) {
			set(
				"duplicateBehavior",
				await asker.select(
					"duplicateBehavior (what adding the Tag again does)",
					[
						{ value: "Ignore", label: "Ignore", hint: "nothing" },
						{ value: "Refresh", label: "Refresh", hint: "restarts the Tag's duration" },
						{ value: "Stack", label: "Stack", hint: "adds another stack" },
					],
					OPTION_DEFAULTS.tag.duplicateBehavior,
				),
			);
		}
		if (need("maxStacks") && options.duplicateBehavior === "Stack") {
			const max = await asker.optionalNumber("maxStacks (most stacks of the Tag allowed; blank for no limit)", { above: 0, integer: true });
			if (max !== "") set("maxStacks", max);
		}
		if (need("duration")) {
			const seconds = await asker.optionalNumber("defaultDuration (seconds the Tag lasts; blank: until removed)", { above: 0 });
			if (seconds !== "") set("duration", seconds);
		}
		if (need("tickInterval")) {
			const seconds = await asker.optionalNumber("tickInterval (seconds between onTick calls; blank for no onTick)", { above: 0 });
			if (seconds !== "") set("tickInterval", seconds);
		}
		if (need("properties")) set("properties", await askPropertyModifiers(asker, known));
	},

	async property(asker, need, set) {
		if (need("defaultBaseValue")) set("defaultBaseValue", await asker.number("defaultBaseValue (the Property's value on an Actor before Tag modifiers)", {}, "0"));
		if (need("autoAssign")) set("autoAssign", await asker.confirm("autoAssign (every Actor gets the Property automatically)", false));
	},

	async resource(asker, need, set, known) {
		if (need("max")) set("max", await asker.numericSource("max", "the Resource's maximum", { initialValue: "100", known: known.property }));
		if (need("min")) {
			const min = await asker.numericSource("min", "the Resource's minimum; none means 0", { initialValue: "0", allowNegative: true, allowNone: true, known: known.property });
			if (min !== undefined) set("min", min);
		}
		if (need("initial")) {
			const initial = await asker.text("initialValue (the Resource's starting value; blank: the maximum)", { validate: optional((value) => numberProblem(value)) });
			if (initial !== "") set("initial", initial);
		}
		if (need("regen")) {
			const regen = await asker.numericSource("regen.rate", "how much the Resource regenerates per second", { initialValue: "1", allowNone: true, known: known.property });
			if (regen !== undefined) set("regen", regen);
		}
		if (need("visibility")) set("visibility", await asker.select("visibility (who can see the Resource)", VISIBILITY, OPTION_DEFAULTS.resource.visibility));
		if (need("autoAssign")) set("autoAssign", await asker.confirm("autoAssign (every Actor gets the Resource automatically)", true));
	},

	async controller(asker, need, set, known) {
		if (need("dependsOn")) set("dependsOn", await asker.ids("dependsOn", "controller keys that must attach before this controller", known.controller));
		if (need("autoAttach")) set("autoAttach", await asker.confirm("autoAttach (attach the controller to every Actor automatically)", true));
	},

	async command(asker, need, set, known, options) {
		if (need("target")) set("target", await asker.select("target (what the Command is about)", NETWORK_TARGET, OPTION_DEFAULTS.command.target));
		if (need("requestFields")) set("requestFields", await asker.fields("request", "data the client sends"));
		if (need("resultFields")) set("resultFields", await asker.fields("result", "data the server sends back"));
		if (need("authorize")) {
			set("authorize", await asker.select("authorize (which players may send the Command)", AUTHORIZATION.filter((policy) => policy.value !== "OwnerActor" || options.target === "Actor"), "deny"));
		}
	},

	async hint(asker, need, set, known, options) {
		if (need("direction")) {
			set(
				"direction",
				await asker.select("direction (who sends the Hint)", [
					{ value: "ServerToClient", label: "ServerToClient", hint: "the server sends the Hint to clients" },
					{ value: "ClientToServer", label: "ClientToServer", hint: "clients send the Hint to the server" },
				]),
			);
		}
		if (need("target")) set("target", await asker.select("target (what the Hint is about)", NETWORK_TARGET, OPTION_DEFAULTS.hint.target));
		if (need("mode")) {
			set(
				"mode",
				await asker.select("mode (which sends of the Hint are delivered)", [
					{ value: "Pulse", label: "Pulse", hint: "every send" },
					{ value: "Latest", label: "Latest", hint: "only the newest value" },
				]),
			);
		}
		if (need("payloadFields")) set("payloadFields", await asker.fields("payload", "data the Hint carries"));
		if (need("authorize") && options.direction === "ClientToServer") {
			set("authorize", await asker.select("authorize (which players may send the Hint)", AUTHORIZATION.filter((policy) => policy.value !== "OwnerActor" || options.target === "Actor"), "deny"));
		}
	},

	async domain(asker, need, set, known, options) {
		if (need("audience")) {
			set(
				"audience",
				await asker.select(
					"audience (which players receive the domain)",
					[
						{ value: "Owner", label: "Owner", hint: "only the player who owns the Actor" },
						{ value: "All", label: "All", hint: "every player" },
					],
					OPTION_DEFAULTS.domain.audience,
				),
			);
		}
		if (need("stateFields")) set("stateFields", await asker.fields("state", "replicated state"));
		if (need("events")) {
			const events = [];
			for (;;) {
				const taken = events.map((event) => event.split("(")[0]);
				const id = await asker.text("events ID (a replicated event such as Finisher; blank to finish)", {
					validate: optional((value) => ENTRY_PROBLEMS.id(value.trim()) ?? (taken.includes(value.trim()) ? "That event already exists." : undefined)),
				});
				if (id === "") break;
				const fields = await asker.fields(`events.${id}.payload`, "data the event carries");
				events.push(fields.length === 0 ? id : `${id}(${fields.join(",")})`);
			}
			set("events", events);
		}
		if (need("observe") && options.events.length === 0) set("observe", await asker.confirm("observe (adds a stub that reports committed changes)"));
	},
};

const EMPTY_CATALOG = Object.freeze({ tag: [], resource: [], action: [], controller: [], lock: [], property: [] });

export async function promptForMissing(kind, given, context = {}) {
	const prompts = context.prompts ?? clack;
	const asker = createAsker(prompts);
	const input = { ...given, options: { ...given.options } };
	const catalog = CATALOGS[kind];

	prompts.intro(catalog.script);

	if (input.name === undefined && input.id === undefined && input.output === undefined) {
		input.name = await asker.text("name (module and file name, such as Fireball)", { validate: (value) => nameProblem((value ?? "").trim()) });
	}
	if (input.id === undefined) {
		const name = input.name ?? input.output?.replace(/\\/g, "/").split("/").at(-1).replace(/\.luau$/, "");
		const id = await asker.text(`${catalog.idField} (blank: ${name}; a namespace such as Combat.${name} is allowed)`, {
			validate: optional((value) => ENTRY_PROBLEMS.id(value.trim())),
		});
		if (id !== "") input.id = id;
	}

	const options = { requestable: false, clientStop: false, events: [], locks: [], interruptibleBy: [], ...OPTION_DEFAULTS[kind], ...input.options };
	const need = (key) => input.options[key] === undefined;
	const set = (key, value) => {
		options[key] = value;
		input.options[key] = value;
	};

	await FLOWS[kind](asker, need, set, context.known ?? EMPTY_CATALOG, options);
	return input;
}
