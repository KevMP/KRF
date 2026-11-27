import path from "node:path";
import { z } from "zod";

import { ExitCode, KrfToolError } from "../errors.js";
import { BUILT_IN_CONTROLLER_KEYS, CATALOGS, PRESENTATION_EVENTS } from "./catalogs.js";
import { parseEvent, parseFields, splitTopLevel } from "./schema.js";

const NAME = /^[A-Z][A-Za-z0-9]*$/;
const ID = /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*$/;
const MAX_NAME_LENGTH = 64;
const MAX_ID_BYTES = 96;
const DEVICE_NAMES = /^(con|prn|aux|nul|com[0-9]|lpt[0-9])$/i;
const RESERVED_NAMES = new Set(["KRF", "ReplicatedStorage", "DURATION"]);
const UNSAFE_CHARACTERS = /[<>:"|?*\u0000-\u001f]/;

export const ACTION_HOOKS = Object.freeze(["onCanStart", "onStart", "onStopRequested", "onUpdate", "onEnd", "onInterrupt", "canBeInterruptedBy"]);
const RECIPE_HOOKS = { instant: "onStart", channel: "onUpdate", held: "onStopRequested", toggle: "onStopRequested" };
const MODIFIER_OPERATIONS = ["set", "add", "multiply", "min", "max"];
const REQUIREMENT_FIELDS = ["min", "max", "minPercent", "maxPercent"];
const AUTHORIZATION = z.enum(["deny", "OwnerActor", "AnyReadyClient"]);

function usage(code, message, hint) {
	return new KrfToolError(code, message, { hint, exitCode: ExitCode.usage });
}

export function nameProblem(name) {
	if (typeof name !== "string" || name === "") return "Enter a name.";
	if (name.length > MAX_NAME_LENGTH) return `Names must be ${MAX_NAME_LENGTH} characters or fewer.`;
	if (!NAME.test(name)) return "Use PascalCase letters and digits, starting with a capital letter, such as Fireball.";
	if (RESERVED_NAMES.has(name) || DEVICE_NAMES.test(name)) return `'${name}' is reserved; choose another name.`;
	return undefined;
}

function idProblem(id) {
	if (typeof id !== "string" || id === "") return "Enter an ID.";
	if (Buffer.byteLength(id) > MAX_ID_BYTES) return `IDs must be ${MAX_ID_BYTES} bytes or fewer.`;
	if (!ID.test(id)) return "Use letters, digits and '_', with '.' between namespace segments, such as Combat.Fireball.";
	if (id.split(".").some((segment) => DEVICE_NAMES.test(segment))) return `'${id}' contains a reserved file name.`;
	return undefined;
}

function finite(text) {
	const value = typeof text === "string" && text.trim() !== "" ? Number(text) : NaN;
	return Number.isFinite(value) ? value : undefined;
}

function parsing(parse) {
	return z.string().transform((value, context) => {
		const result = parse(value);
		if (result?.problem !== undefined) {
			context.addIssue({ code: "custom", message: result.problem });
			return z.NEVER;
		}
		return result;
	});
}

function schemaParsing(parse) {
	return (value) => {
		try {
			return parse(value);
		} catch (error) {
			if (error instanceof SyntaxError) return { problem: error.message };
			throw error;
		}
	};
}

function uniqueBy(key, label) {
	return (entries, context) => {
		const keys = entries.map(key);
		const duplicate = keys.find((value, index) => keys.indexOf(value) !== index);
		if (duplicate !== undefined) context.addIssue({ code: "custom", message: label(duplicate) });
	};
}

const idList = z
	.array(parsing((value) => (idProblem(value) ? { problem: idProblem(value) } : value)))
	.default([])
	.superRefine(uniqueBy((id) => id, (id) => `'${id}' is listed twice`));

const number = (schema) => z.preprocess((value) => (typeof value === "string" && value.trim() !== "" ? Number(value) : value), schema);
const positive = number(z.number().positive());

function parseKeyed(value, operations, example) {
	const match = /^([^:]*):(.*)$/.exec(value);
	if (!match) return { problem: `'${value}' must look like ${example}` };

	const key = match[1].trim();
	if (!ID.test(key)) return { problem: `'${key}' is not a valid name; use letters, digits and '_', such as ${example.split(":")[0]}` };

	const values = {};
	for (const part of match[2].split(",")) {
		const entry = /^\s*([A-Za-z]+)\s*=\s*(\S+)\s*$/.exec(part);
		if (!entry || !(entry[1] in operations)) {
			return { problem: `'${part.trim()}' must be one of ${Object.keys(operations).join(", ")} with a value, such as ${example.split(":")[1]}` };
		}
		if (entry[1] in values) return { problem: `${key} gives ${entry[1]} twice` };
		const parsed = operations[entry[1]](entry[2]);
		if (parsed === undefined) return { problem: `${key}: '${entry[2]}' is not a valid ${entry[1]}` };
		values[entry[1]] = parsed;
	}

	return { key, values: Object.fromEntries(Object.keys(operations).filter((field) => field in values).map((field) => [field, values[field]])) };
}

const NUMBER_OPERATIONS = (fields) => Object.fromEntries(fields.map((field) => [field, finite]));

export function parsePropertyModifier(value) {
	const parsed = parseKeyed(value, NUMBER_OPERATIONS(MODIFIER_OPERATIONS), "WalkSpeed:multiply=0.5,min=4");
	if (parsed.problem) return parsed;
	if ("set" in parsed.values && Object.keys(parsed.values).length > 1) {
		return { problem: `${parsed.key}: set cannot be combined with add, multiply, min or max` };
	}
	return { property: parsed.key, modifier: parsed.values };
}

function parseRequirement(value) {
	const parsed = parseKeyed(value, NUMBER_OPERATIONS(REQUIREMENT_FIELDS), "Mana:min=10,maxPercent=0.5");
	if (parsed.problem) return parsed;
	const { min, max, minPercent, maxPercent } = parsed.values;
	for (const percent of [minPercent, maxPercent]) {
		if (percent !== undefined && (percent < 0 || percent > 1)) return { problem: `${parsed.key}: minPercent and maxPercent must be between 0 and 1` };
	}
	if (min !== undefined && max !== undefined && min > max) return { problem: `${parsed.key}: min is greater than max` };
	if (minPercent !== undefined && maxPercent !== undefined && minPercent > maxPercent) return { problem: `${parsed.key}: minPercent is greater than maxPercent` };
	return { resource: parsed.key, requirement: parsed.values };
}

function parseCost(value) {
	const shorthand = /^([^:=]+)=(.+)$/.exec(value);
	const parsed = shorthand
		? { key: shorthand[1].trim(), values: { amount: finite(shorthand[2]) } }
		: parseKeyed(value, { amount: finite, percent: finite, multiplierProperty: (text) => (ID.test(text) ? text : undefined) }, "Mana:percent=0.1,multiplierProperty=CostScale");
	if (parsed.problem) return parsed;
	if (!ID.test(parsed.key)) return { problem: `'${parsed.key}' is not a Resource ID` };

	const { amount, percent } = parsed.values;
	if ((amount === undefined) === (percent === undefined)) return { problem: `${parsed.key}: give exactly one of amount or percent, such as Mana=10 or Mana:percent=0.1` };
	if ((amount ?? percent) <= 0) return { problem: `${parsed.key}: the cost must be positive` };
	return { resource: parsed.key, cost: parsed.values };
}

function parseTagApplication(value) {
	const [id, duration, extra] = value.split(":").map((part) => part.trim());
	if (extra !== undefined || idProblem(id)) return { problem: `'${value}' must be TagId or TagId:seconds, such as Burning:3` };
	if (duration === undefined) return { id };
	const seconds = finite(duration);
	if (seconds === undefined || seconds <= 0) return { problem: `${id}: the duration must be a positive number of seconds` };
	return { id, duration: seconds };
}

function parseNumericSource(value) {
	const constant = finite(value);
	if (constant !== undefined) return { value: constant };
	if (ID.test(value.trim())) return { propertyName: value.trim() };
	return { problem: `'${value}' must be a number or a registered Property ID such as MaxStamina` };
}

const fieldList = z
	.array(z.string())
	.default([])
	.transform((specs, context) => {
		const parsed = schemaParsing(parseFields)(specs.flatMap((spec) => splitTopLevel(spec)));
		if (parsed?.problem) {
			context.addIssue({ code: "custom", message: parsed.problem });
			return z.NEVER;
		}
		return parsed;
	});

export const ENTRY_PROBLEMS = Object.freeze({
	id: idProblem,
	tagApplication: (value) => parseTagApplication(value).problem,
	requirement: (value) => parseRequirement(value).problem,
	cost: (value) => parseCost(value).problem,
	property: (value) => parsePropertyModifier(value).problem,
	numericSource: (value) => parseNumericSource(value).problem,
	field: (value) => schemaParsing(parseFields)(splitTopLevel(value))?.problem,
	event: (value) => schemaParsing(parseEvent)(value)?.problem,
});

export const OPTION_DEFAULTS = Object.freeze({
	action: Object.freeze({ recipe: "instant", duration: 1, requestable: false, autoGrant: false }),
	tag: Object.freeze({ visibility: "ServerOnly", duplicateBehavior: "Ignore" }),
	resource: Object.freeze({ max: "100", visibility: "ServerOnly", autoAssign: true }),
	property: Object.freeze({ defaultBaseValue: 0, autoAssign: false }),
	controller: Object.freeze({ autoAttach: true }),
	command: Object.freeze({ target: "Actor", authorize: "deny" }),
	hint: Object.freeze({ direction: "ServerToClient", target: "Actor", mode: "Pulse", authorize: "deny" }),
	domain: Object.freeze({ audience: "Owner", observe: false }),
	presentation: Object.freeze({ event: "Action.Started", predict: true }),
});

const visibility = z.enum(["ServerOnly", "ClientVisible"]);
const networkTarget = z.enum(["Actor", "None"]);

const OPTION_SCHEMAS = {
	action: z.strictObject({
		recipe: z.enum(["instant", "channel", "held", "toggle"]).default(OPTION_DEFAULTS.action.recipe),
		duration: positive.optional(),
		requestable: z.boolean().default(OPTION_DEFAULTS.action.requestable),
		autoGrant: z.boolean().default(OPTION_DEFAULTS.action.autoGrant),
		visibility: visibility.optional(),
		requiredTags: idList,
		blockedTags: idList,
		activeTags: z.array(parsing(parseTagApplication)).default([]).superRefine(uniqueBy((entry) => entry.id, (id) => `'${id}' is listed twice`)),
		appliedTags: z.array(parsing(parseTagApplication)).default([]).superRefine(uniqueBy((entry) => entry.id, (id) => `'${id}' is listed twice`)),
		requirements: z.array(parsing(parseRequirement)).default([]).superRefine(uniqueBy((entry) => entry.resource, (id) => `'${id}' has more than one requirement`)),
		costs: z.array(parsing(parseCost)).default([]).superRefine(uniqueBy((entry) => entry.resource, (id) => `'${id}' has more than one cost`)),
		locks: idList,
		interruptibleBy: idList,
		hooks: z.array(z.enum(ACTION_HOOKS)).default([]).superRefine(uniqueBy((hook) => hook, (hook) => `${hook} is listed twice`)),
		startFields: fieldList,
		stopFields: fieldList,
		clientStop: z.boolean().default(false),
		allowInputInterrupt: z.boolean().default(false),
		onDisconnect: z.enum(["Keep", "Interrupt"]).optional(),
	}),
	tag: z.strictObject({
		visibility: visibility.default(OPTION_DEFAULTS.tag.visibility),
		duplicateBehavior: z.enum(["Ignore", "Refresh", "Stack"]).default(OPTION_DEFAULTS.tag.duplicateBehavior),
		maxStacks: number(z.number().int().positive()).optional(),
		duration: positive.optional(),
		tickInterval: positive.optional(),
		properties: z
			.array(parsing(parsePropertyModifier))
			.default([])
			.superRefine(uniqueBy((entry) => entry.property, (property) => `'${property}' is modified twice; give every operation in one --property`)),
	}),
	resource: z.strictObject({
		max: parsing(parseNumericSource).prefault(OPTION_DEFAULTS.resource.max),
		min: parsing(parseNumericSource).optional(),
		initial: number(z.number()).optional(),
		regen: parsing(parseNumericSource).optional(),
		visibility: visibility.default(OPTION_DEFAULTS.resource.visibility),
		autoAssign: z.boolean().default(OPTION_DEFAULTS.resource.autoAssign),
	}),
	property: z.strictObject({
		defaultBaseValue: number(z.number()).default(OPTION_DEFAULTS.property.defaultBaseValue),
		autoAssign: z.boolean().default(OPTION_DEFAULTS.property.autoAssign),
	}),
	controller: z.strictObject({
		dependsOn: idList,
		autoAttach: z.boolean().default(OPTION_DEFAULTS.controller.autoAttach),
	}),
	command: z.strictObject({
		target: networkTarget.default(OPTION_DEFAULTS.command.target),
		requestFields: fieldList,
		resultFields: fieldList,
		authorize: AUTHORIZATION.default(OPTION_DEFAULTS.command.authorize),
	}),
	hint: z.strictObject({
		direction: z.enum(["ServerToClient", "ClientToServer"]).default(OPTION_DEFAULTS.hint.direction),
		target: networkTarget.default(OPTION_DEFAULTS.hint.target),
		mode: z.enum(["Pulse", "Latest"]).default(OPTION_DEFAULTS.hint.mode),
		payloadFields: fieldList,
		authorize: AUTHORIZATION.default(OPTION_DEFAULTS.hint.authorize),
	}),
	presentation: z.strictObject({
		event: z.enum(PRESENTATION_EVENTS).default(OPTION_DEFAULTS.presentation.event),
		sourceId: z.string().refine((value) => value.trim() !== "" && !/[\u0000-\u001f]/.test(value), "enter an exact source ID without control characters"),
		predict: z.boolean().default(OPTION_DEFAULTS.presentation.predict),
	}),
	domain: z.strictObject({
		audience: z.enum(["Owner", "All"]).default(OPTION_DEFAULTS.domain.audience),
		stateFields: fieldList,
		events: z
			.array(parsing(schemaParsing(parseEvent)))
			.default([])
			.superRefine((events, context) => {
				const problem = events.map((event) => idProblem(event.id)).find(Boolean);
				if (problem) context.addIssue({ code: "custom", message: problem });
				uniqueBy((event) => event.id, (id) => `the event '${id}' is listed twice`)(events, context);
			}),
		observe: z.boolean().default(OPTION_DEFAULTS.domain.observe),
	}),
};

const FLAGS = {
	requiredTags: "--required-tag",
	activeTags: "--active-tag",
	appliedTags: "--applied-tag",
	blockedTags: "--blocked-tag",
	requirements: "--requirement",
	costs: "--cost",
	locks: "--lock",
	hooks: "--hook",
	startFields: "--start-field",
	stopFields: "--stop-field",
	dependsOn: "--depends-on",
	autoGrant: "--auto-grant",
	autoAssign: "--no-auto-assign",
	autoAttach: "--no-auto-attach",
	predict: "--no-predict",
	duplicateBehavior: "--duplicate-behavior",
	properties: "--property",
	requestFields: "--request-field",
	resultFields: "--result-field",
	payloadFields: "--payload-field",
	stateFields: "--state-field",
	events: "--event",
};

const flagFor = (field) => FLAGS[field] ?? `--${field.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`)}`;

function normalizeOutput(output) {
	const posix = output.replace(/\\/g, "/");
	if (path.posix.isAbsolute(posix) || path.win32.isAbsolute(output) || /^[A-Za-z]:/.test(posix)) {
		throw usage("UnsafeOutputPath", `--output must be relative to the project root, not '${output}'.`);
	}

	const segments = posix.split("/").filter((segment) => segment !== "" && segment !== ".");
	if (segments.includes("..")) throw usage("UnsafeOutputPath", `--output must stay inside the project: '${output}'.`);
	if (segments[0] !== "src" || segments.length < 3 || !segments.at(-1).endsWith(".luau")) {
		throw usage("OutputOutsideSource", `--output must be a .luau file inside a folder under src/, not '${output}'.`, "For example: --output src/server/Actions/Combat/Fireball.luau");
	}

	for (const segment of segments) {
		if (UNSAFE_CHARACTERS.test(segment) || /[. ]$/.test(segment) || DEVICE_NAMES.test(segment.split(".")[0])) {
			throw usage("UnsafeOutputPath", `--output contains an unusable file name: '${segment}'.`);
		}
	}

	const name = segments.at(-1).slice(0, -".luau".length);
	const problem = nameProblem(name);
	if (problem) throw usage("InvalidName", `--output must name the module file after the definition. ${problem}`);

	return { path: segments.join("/"), name };
}

function resolveIdentity(kind, input) {
	let name = input.name;
	let output;

	if (input.output !== undefined) {
		const normalized = normalizeOutput(input.output);
		if (name !== undefined && name !== normalized.name) {
			throw usage("NameOutputMismatch", `--name ${name} does not match the --output file ${normalized.name}.luau.`, "Omit --name; the file name is the module name.");
		}
		name = normalized.name;
		output = normalized.path;
	}

	if (name === undefined && input.id !== undefined) name = input.id.split(".").at(-1);
	if (name === undefined) {
		throw usage("NameMissing", "A name is required when not running interactively.", `Pass it with --name, for example: npm run ${CATALOGS[kind].script} -- --name Example`);
	}

	const nameIssue = nameProblem(name);
	if (nameIssue) {
		throw usage("InvalidName", `Invalid name '${name}'. ${nameIssue}`, input.name === undefined ? "Pass a PascalCase --name for the module." : undefined);
	}

	const id = input.id ?? name;
	const idIssue = idProblem(id);
	if (idIssue) throw usage("InvalidId", `Invalid --id '${id}'. ${idIssue}`);
	if (id === "KRF" || id.startsWith("KRF.")) throw usage("IdReserved", `'${id}' is reserved for KRF's own definitions.`);
	if (kind === "controller" && BUILT_IN_CONTROLLER_KEYS.includes(id)) {
		throw usage("IdReserved", `'${id}' is a built-in KRF controller key.`);
	}

	return { name, id, namespace: id.split(".").slice(0, -1), output };
}

function checkAction(options, given) {
	if (options.duration !== undefined && options.recipe !== "channel") {
		throw usage("InvalidOption", "--duration applies only to the channel recipe.");
	}
	if (options.hooks.includes(RECIPE_HOOKS[options.recipe])) {
		throw usage("InvalidOption", `The ${options.recipe} recipe already writes ${RECIPE_HOOKS[options.recipe]}; drop --hook ${RECIPE_HOOKS[options.recipe]}.`);
	}
	if (!options.requestable) {
		const requestOnly = ["startFields", "stopFields", "clientStop", "allowInputInterrupt", "onDisconnect"].find((field) => given.includes(field));
		if (requestOnly) throw usage("InvalidOption", `${flagFor(requestOnly)} describes the client request, so it needs --requestable.`);
	}
	if (options.recipe === "instant" && options.requestable && (options.clientStop || options.stopFields.length > 0)) {
		throw usage("InvalidOption", "The instant recipe ends the Action in onStart, so a Stop never reaches it; use --recipe toggle, held or channel.");
	}
	if (options.recipe === "held" && options.onDisconnect === "Keep") {
		throw usage("InvalidOption", "A held Action requires the client to release its input, so a disconnect must interrupt it; drop --on-disconnect Keep.");
	}
	const clientStop = options.requestable && options.recipe !== "held" && options.recipe !== "toggle" && (options.clientStop || options.stopFields.length > 0);
	return {
		...options,
		clientStop,
		hooks: clientStop && !options.hooks.includes("onStopRequested") ? [...options.hooks, "onStopRequested"] : options.hooks,
		duration: options.recipe === "channel" ? (options.duration ?? OPTION_DEFAULTS.action.duration) : undefined,
		visibility: options.visibility ?? (options.requestable ? "ClientVisible" : "ServerOnly"),
	};
}

function checkResource(options) {
	const minimum = options.min === undefined ? 0 : options.min.value;
	const maximum = options.max.value;
	if (minimum !== undefined && maximum !== undefined && minimum > maximum) throw usage("InvalidOption", `The minimum ${minimum} is greater than the maximum ${maximum}.`);
	if (options.regen !== undefined && options.regen.value < 0) throw usage("InvalidOption", "--regen cannot be negative.");

	const initial = options.initial ?? maximum;
	if (initial !== undefined && maximum !== undefined && initial > maximum) throw usage("InvalidOption", `--initial ${initial} is greater than the maximum ${maximum}.`);
	if (initial !== undefined && minimum !== undefined && initial < minimum) throw usage("InvalidOption", `--initial ${initial} is less than the minimum ${minimum}.`);
	return { ...options, initial };
}

function checkNetwork(kind, options) {
	if (options.authorize === "OwnerActor" && options.target !== "Actor") {
		throw usage("InvalidOption", "--authorize OwnerActor needs --target Actor.");
	}
	if (kind === "hint" && options.direction === "ServerToClient" && options.authorize !== "deny") {
		throw usage("InvalidOption", "--authorize applies only to ClientToServer Hints.");
	}
	return options;
}

export function normalizeRequest(kind, input) {
	const catalog = CATALOGS[kind];
	if (!catalog) throw usage("UnknownKind", `Unknown definition kind '${kind}'.`);

	const identity = resolveIdentity(kind, input);
	const parsed = OPTION_SCHEMAS[kind].safeParse(input.options ?? {});
	if (!parsed.success) {
		const issue = parsed.error.issues[0];
		throw usage("InvalidOption", `Invalid ${flagFor(String(issue.path[0]))}: ${issue.message}.`, `Run npm run ${catalog.script} -- --help for supported values.`);
	}

	let options = parsed.data;
	if (kind === "action") options = checkAction(options, Object.keys(input.options ?? {}));
	if (kind === "resource") options = checkResource(options);
	if (kind === "command" || kind === "hint") options = checkNetwork(kind, options);
	if (kind === "tag" && options.maxStacks !== undefined && options.duplicateBehavior !== "Stack") {
		throw usage("InvalidOption", "--max-stacks needs --duplicate-behavior Stack.");
	}
	if (kind === "controller" && options.dependsOn.includes(identity.id)) {
		throw usage("InvalidOption", `Controller '${identity.id}' cannot depend on itself.`);
	}
	if (kind === "domain" && options.events.length > 0) options = { ...options, observe: true };

	return Object.freeze({ kind, ...identity, options: Object.freeze(options) });
}
