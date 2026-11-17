import * as clack from "@clack/prompts";

import { ExitCode, KrfToolError } from "../errors.js";
import { CATALOGS } from "./catalogs.js";
import { isIdentifier } from "./luau.js";
import { ENTRY_PROBLEMS, OPTION_DEFAULTS, nameProblem } from "./request.js";

const OTHER = "\u0000other";

const RECIPE_HOOKS = { instant: "onStart", channel: "onUpdate", held: "onStopRequested" };

const HOOKS = [
	{ value: "onCanStart", label: "onCanStart", hint: "an extra check that can refuse to start it" },
	{ value: "onStart", label: "onStart", hint: "runs once when it starts" },
	{ value: "onStopRequested", label: "onStopRequested", hint: "runs when a Stop is requested" },
	{ value: "onUpdate", label: "onUpdate", hint: "runs every frame while it is active" },
	{ value: "onEnd", label: "onEnd", hint: "runs when it ends normally" },
	{ value: "onInterrupt", label: "onInterrupt", hint: "runs when something interrupts it" },
	{ value: "canBeInterruptedBy", label: "canBeInterruptedBy", hint: "decides each time whether an allowed Action may take its locks" },
];

const VISIBILITY = [
	{ value: "ServerOnly", label: "Server only", hint: "clients never see it" },
	{ value: "ClientVisible", label: "Visible to clients", hint: "replicated so client code and UI can read it" },
];

const NETWORK_TARGET = [
	{ value: "Actor", label: "An Actor", hint: "sent about one Actor, such as the player's character" },
	{ value: "None", label: "Nothing in particular", hint: "not tied to any Actor" },
];

const AUTHORIZATION = [
	{ value: "deny", label: "Reject everything for now", hint: "writes an authorize stub you fill in" },
	{ value: "OwnerActor", label: "Only the player who owns the Actor", hint: "KRF's OwnerActor policy" },
	{ value: "AnyReadyClient", label: "Any connected player", hint: "KRF's AnyReadyClient policy" },
];

const TYPES = [
	{ value: "Boolean", label: "True or false", hint: "Boolean" },
	{ value: "U8", label: "Whole number from 0 to 255", hint: "U8" },
	{ value: "U16", label: "Whole number from 0 to 65,535", hint: "U16" },
	{ value: "U32", label: "Whole number from 0 to about 4 billion", hint: "U32" },
	{ value: "I8", label: "Whole number from -128 to 127", hint: "I8" },
	{ value: "I16", label: "Whole number from -32,768 to 32,767", hint: "I16" },
	{ value: "I32", label: "Whole number from about -2 billion to 2 billion", hint: "I32" },
	{ value: "F32", label: "Decimal number", hint: "F32" },
	{ value: "F64", label: "High-precision decimal number", hint: "F64" },
	{ value: "String", label: "Text", hint: "String" },
	{ value: "Enum", label: "One of a fixed set of names", hint: "Enum" },
	{ value: "Array", label: "A list of values", hint: "Array" },
	{ value: "Map", label: "A lookup table", hint: "Map" },
];

const MODIFIER_OPERATIONS = [
	{ value: "add", label: "Add an amount", hint: "add" },
	{ value: "multiply", label: "Multiply it", hint: "multiply" },
	{ value: "min", label: "Never let it go below a value", hint: "min" },
	{ value: "max", label: "Never let it go above a value", hint: "max" },
];

const isBlank = (value) => (value ?? "").trim() === "";

function numberProblem(value, { min, above, integer } = {}) {
	if (isBlank(value)) return "Enter a number.";
	const parsed = Number(value);
	if (!Number.isFinite(parsed)) return "Enter a number.";
	if (integer && !Number.isInteger(parsed)) return "Enter a whole number.";
	if (above !== undefined && parsed <= above) return `Enter a number greater than ${above}.`;
	if (min !== undefined && parsed < min) return `Enter a number of at least ${min}.`;
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

function fieldNameProblem(taken) {
	return (value) => {
		const name = (value ?? "").trim();
		if (!isIdentifier(name)) return "Use letters, digits and '_', starting with a letter, such as Amount.";
		if (taken.includes(name)) return `${name} is already a field.`;
		return undefined;
	};
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

		async ids(message, noun, known) {
			if (known.length === 0) {
				const answer = await asker.text(`${message} (separated by commas, blank for none)`, { validate: optional(idListProblem) });
				return answer === "" ? [] : answer.split(",").map((id) => id.trim());
			}
			const picked = await asker.multiselect(`${message} (space to select, enter to continue)`, [
				...known.map((id) => ({ value: id, label: id })),
				{ value: OTHER, label: "Not in this list (type it)" },
			]);
			const chosen = picked.filter((id) => id !== OTHER);
			if (!picked.includes(OTHER)) return chosen;
			const more = await asker.text(`Which other ${noun}s? (separated by commas)`, { validate: idListProblem });
			return [...chosen, ...more.split(",").map((id) => id.trim())];
		},

		async id(message, noun, known) {
			if (known.length > 0) {
				const picked = await asker.select(message, [...known.map((id) => ({ value: id, label: id })), { value: OTHER, label: "Not in this list (type it)" }]);
				if (picked !== OTHER) return picked;
			}
			return asker.text(known.length > 0 ? `Which ${noun}?` : message, { validate: (value) => ENTRY_PROBLEMS.id((value ?? "").trim()) });
		},

		async each(first, next, askOne) {
			const entries = [];
			for (let more = await asker.confirm(first); more; more = await asker.confirm(next)) entries.push(await askOne(entries));
			return entries;
		},

		async type(subject) {
			const kind = await asker.select(`What kind of value is ${subject}?`, TYPES);
			switch (kind) {
				case "String":
					return `String(${await asker.number(`Longest text ${subject} can hold, in bytes`, { above: 0, integer: true }, "32")})`;
				case "Enum": {
					const names = await asker.text(`Names ${subject} can be, separated by commas`, {
						placeholder: "Fire, Ice",
						validate: (value) => ENTRY_PROBLEMS.field(`Value:Enum(${(value ?? "").split(",").map((name) => name.trim()).join("|")})`),
					});
					return `Enum(${names.split(",").map((name) => name.trim()).join("|")})`;
				}
				case "Array": {
					const element = await asker.type(`each item in ${subject}`);
					return `Array(${element},${await asker.number(`Most items ${subject} can hold`, { above: 0, integer: true }, "8")})`;
				}
				case "Map": {
					const key = await asker.type(`each key in ${subject}`);
					const value = await asker.type(`each value in ${subject}`);
					return `Map(${key},${value},${await asker.number(`Most entries ${subject} can hold`, { above: 0, integer: true }, "8")})`;
				}
				default:
					return kind;
			}
		},

		fields(first, next) {
			return asker.each(first, next, async (entries) => {
				const taken = entries.map((entry) => entry.split(":")[0]);
				const name = await asker.text("Field name", { placeholder: "Amount", validate: fieldNameProblem(taken) });
				const type = await asker.type(name);
				return (await asker.confirm(`Can ${name} be left out?`)) ? `${name}:Optional(${type})` : `${name}:${type}`;
			});
		},

		async numericSource(subject, { initialValue, allowNegative }) {
			const from = await asker.select(`Where does ${subject} come from?`, [
				{ value: "value", label: "A fixed number" },
				{ value: "property", label: "A property", hint: "Tags and stats can change it while the game runs" },
			]);
			const constraints = allowNegative ? {} : { min: 0 };
			if (from === "value") return asker.number(`What is ${subject}?`, constraints, initialValue);
			const property = await asker.text("Property name", { placeholder: "MaxStamina", validate: (value) => ENTRY_PROBLEMS.id((value ?? "").trim()) });
			const base = await asker.number(`${property}'s default base value`, constraints, initialValue);
			return `${property}=${base}`;
		},
	};
	return asker;
}

async function askActionTags(asker, known, kind) {
	const active = kind === "activeTags";
	return asker.each(
		active ? "While it runs, should the Actor have a Tag, such as Casting? (removed when it ends)" : "When it starts, should it give the Actor a Tag that stays after it ends, such as Burning?",
		active ? "Add another Tag the Actor has while it runs?" : "Add another Tag that stays after it ends?",
		async () => {
			const tag = await asker.id("Which Tag?", "Tag", known.tag);
			const seconds = await asker.optionalNumber(
				active ? `Remove ${tag} after how many seconds? (blank: when it ends)` : `How many seconds does ${tag} last? (blank: ${tag}'s own default duration)`,
				{ above: 0 },
			);
			return seconds === "" ? tag : `${tag}:${seconds}`;
		},
	);
}

async function askRequirement(asker, known) {
	const resource = await asker.id("Which Resource must be at a certain level?", "Resource", known.resource);
	const checks = await asker.multiselect(`Which checks on ${resource}? (space to select, enter to continue)`, [
		{ value: "min", label: "At least an amount" },
		{ value: "max", label: "At most an amount" },
		{ value: "minPercent", label: "At least a percent of its maximum" },
		{ value: "maxPercent", label: "At most a percent of its maximum" },
	]);
	const parts = [];
	for (const check of checks.length > 0 ? checks : ["min"]) {
		if (check === "min") parts.push(`min=${await asker.number(`${resource} must be at least`, {})}`);
		if (check === "max") parts.push(`max=${await asker.number(`${resource} must be at most`, {})}`);
		if (check === "minPercent") parts.push(`minPercent=${percent(await asker.number(`${resource} must be at least what percent of its maximum? (0-100)`, { min: 0 }))}`);
		if (check === "maxPercent") parts.push(`maxPercent=${percent(await asker.number(`${resource} must be at most what percent of its maximum? (0-100)`, { min: 0 }))}`);
	}
	const spec = `${resource}:${parts.join(",")}`;
	const problem = ENTRY_PROBLEMS.requirement(spec);
	if (problem) throw new KrfToolError("InvalidOption", `That requirement does not work: ${problem}.`, { exitCode: ExitCode.usage });
	return spec;
}

async function askCost(asker, known) {
	const resource = await asker.id("Which Resource does it cost?", "Resource", known.resource);
	const measure = await asker.select(`How is the ${resource} cost measured?`, [
		{ value: "amount", label: "A fixed amount" },
		{ value: "percent", label: `A percent of ${resource}'s full range`, hint: "100 means a whole bar" },
	]);
	const value =
		measure === "amount"
			? await asker.number(`How much ${resource} does it cost?`, { above: 0 })
			: percent(await asker.number(`What percent of ${resource}'s range does it cost?`, { above: 0 }));
	if (!(await asker.confirm(`Should a property scale the ${resource} cost? (for example a cost multiplier stat)`))) {
		return measure === "amount" ? `${resource}=${value}` : `${resource}:percent=${value}`;
	}
	const property = await asker.id("Which property scales it?", "property", known.property);
	return `${resource}:${measure}=${value},multiplierProperty=${property}`;
}

async function askPropertyModifier(asker, known, taken) {
	const available = known.property.filter((property) => !taken.includes(property));
	const property = await asker.id("Which property does it change?", "property", available);
	const how = await asker.select(`How does it change ${property}?`, [
		{ value: "adjust", label: "Adjust it", hint: "add, multiply, or keep it within limits" },
		{ value: "set", label: "Replace it with a fixed value", hint: "for example 0 to freeze movement" },
	]);
	if (how === "set") return `${property}:set=${await asker.number(`Set ${property} to`, {})}`;

	const operations = await asker.multiselect(`How does it adjust ${property}? (space to select, enter to continue)`, MODIFIER_OPERATIONS);
	const parts = [];
	for (const operation of operations.length > 0 ? operations : ["add"]) {
		const label = { add: `Add how much to ${property}?`, multiply: `Multiply ${property} by`, min: `Keep ${property} at or above`, max: `Keep ${property} at or below` }[operation];
		parts.push(`${operation}=${await asker.number(label, {})}`);
	}
	return `${property}:${parts.join(",")}`;
}

const FLOWS = {
	async action(asker, need, set, known, options) {
		if (need("recipe")) {
			set(
				"recipe",
				await asker.select("How does it end?", [
					{ value: "instant", label: "Right away", hint: "instant: onStart ends it" },
					{ value: "channel", label: "After a duration", hint: "channel: onUpdate ends it after a time" },
					{ value: "held", label: "When the player lets go", hint: "held: lasts while the input is held" },
				]),
			);
		}
		if (need("duration") && options.recipe === "channel") set("duration", await asker.number("How many seconds does it last?", { above: 0 }, "1"));
		if (need("autoGrant")) set("autoGrant", await asker.confirm("Should every Actor be able to use it? (no: you grant it with ActionController:SetGrants)"));
		if (need("requiredTags")) set("requiredTags", await asker.ids("Tags the Actor must have before it can start", "Tag", known.tag));
		if (need("blockedTags")) set("blockedTags", await asker.ids("Tags that stop it from starting", "Tag", known.tag));
		if (need("activeTags")) set("activeTags", await askActionTags(asker, known, "activeTags"));
		if (need("appliedTags")) set("appliedTags", await askActionTags(asker, known, "appliedTags"));
		if (need("requirements")) {
			set("requirements", await asker.each("Must a Resource be at a certain level before it can start?", "Add another Resource requirement?", () => askRequirement(asker, known)));
		}
		if (need("costs")) set("costs", await asker.each("Does starting it cost a Resource?", "Add another cost?", () => askCost(asker, known)));
		if (need("locks")) {
			set(
				"locks",
				(await asker.confirm("Should it block other Actions on the same Actor while it runs? (locks: Actions that share a lock never run at the same time)"))
					? await asker.ids("Which locks does it hold?", "lock", known.lock)
					: [],
			);
		}
		if (need("interruptibleBy") && options.locks.length > 0) {
			set(
				"interruptibleBy",
				(await asker.confirm(`If another Action needs ${options.locks.join(", ")} while this one runs, may some Actions cancel this one and take over?`))
					? await asker.ids("Which Actions may cancel it and take over its locks?", "Action", known.action)
					: [],
			);
		}
		if (need("hooks")) {
			const available = HOOKS.filter((hook) => hook.value !== RECIPE_HOOKS[options.recipe] && (hook.value !== "canBeInterruptedBy" || options.interruptibleBy?.length > 0));
			set("hooks", await asker.multiselect("Which other lifecycle hooks should it have? (space to select, enter to continue)", available));
		}
		if (need("requestable")) set("requestable", await asker.confirm("Can players start it from the client, for example with a key?"));
		if (!options.requestable) return;

		if (need("startFields")) set("startFields", await asker.fields("Does the client send any data when it starts it?", "Add another start field?"));
		if (need("clientStop") && options.recipe !== "held") set("clientStop", await asker.confirm("Can the player stop it early?"));
		if (need("stopFields") && (options.recipe === "held" || options.clientStop)) {
			set("stopFields", await asker.fields("Does the client send any data when it stops it?", "Add another stop field?"));
		}
		if (need("allowInputInterrupt") && options.recipe !== "held") {
			set("allowInputInterrupt", await asker.confirm("Can the player's input cancel it, for example when the key binding is removed?"));
		}
		if (need("onDisconnect") && options.recipe !== "held") {
			set(
				"onDisconnect",
				await asker.select(
					"If the player who started it leaves the game:",
					[
						{ value: "Keep", label: "Let it keep running" },
						{ value: "Interrupt", label: "Interrupt it" },
					],
					"Keep",
				),
			);
		}
	},

	async tag(asker, need, set, known, options) {
		if (need("visibility")) set("visibility", await asker.select("Who can see it?", VISIBILITY, OPTION_DEFAULTS.tag.visibility));
		if (need("duplicateBehavior")) {
			set(
				"duplicateBehavior",
				await asker.select(
					"What happens when it is added to an Actor that already has it?",
					[
						{ value: "Ignore", label: "Nothing", hint: "Ignore" },
						{ value: "Refresh", label: "Its duration restarts", hint: "Refresh" },
						{ value: "Stack", label: "It stacks", hint: "Stack: each copy counts separately" },
					],
					OPTION_DEFAULTS.tag.duplicateBehavior,
				),
			);
		}
		if (need("maxStacks") && options.duplicateBehavior === "Stack") {
			const max = await asker.optionalNumber("Most stacks it can have (blank: no limit)", { above: 0, integer: true });
			if (max !== "") set("maxStacks", max);
		}
		if (need("duration")) {
			const seconds = await asker.optionalNumber("How many seconds does it last by default? (blank: until removed)", { above: 0 });
			if (seconds !== "") set("duration", seconds);
		}
		if (need("tickInterval") && (await asker.confirm("Should it run code repeatedly while active? (onTick)"))) {
			set("tickInterval", await asker.number("Every how many seconds?", { above: 0 }, "1"));
		}
		if (need("properties")) {
			set("properties", await asker.each("Does it change a property, such as WalkSpeed, while active?", "Change another property?", (entries) => askPropertyModifier(asker, known, entries.map((entry) => entry.split(":")[0]))));
		}
	},

	async resource(asker, need, set, known) {
		if (need("max")) set("max", await asker.numericSource("its maximum", { initialValue: "100" }));
		if (need("min") && (await asker.confirm("Can it have a minimum other than 0?"))) set("min", await asker.numericSource("its minimum", { initialValue: "0", allowNegative: true }));
		if (need("initial")) {
			const initial = await asker.text("What value does it start at? (blank: its maximum)", { validate: optional((value) => numberProblem(value)) });
			if (initial !== "") set("initial", initial);
		}
		if (need("regen") && (await asker.confirm("Does it regenerate over time?"))) set("regen", await asker.numericSource("its regeneration per second", { initialValue: "1" }));
		if (need("visibility")) set("visibility", await asker.select("Who can see it?", VISIBILITY, OPTION_DEFAULTS.resource.visibility));
		if (need("autoAssign")) set("autoAssign", await asker.confirm("Should every Actor have it automatically?", true));
	},

	async controller(asker, need, set, known) {
		if (need("dependsOn")) set("dependsOn", await asker.ids("Which controllers must be attached before it?", "controller", known.controller));
		if (need("autoAttach")) set("autoAttach", await asker.confirm("Should it attach to every Actor automatically?", true));
	},

	async command(asker, need, set, known, options) {
		if (need("target")) set("target", await asker.select("What is the command about?", NETWORK_TARGET, OPTION_DEFAULTS.command.target));
		if (need("requestFields")) set("requestFields", await asker.fields("Does the client send any data with it?", "Add another request field?"));
		if (need("resultFields")) set("resultFields", await asker.fields("Does the server send data back with the result?", "Add another result field?"));
		if (need("authorize")) {
			set("authorize", await asker.select("Which players may send it?", AUTHORIZATION.filter((policy) => policy.value !== "OwnerActor" || options.target === "Actor"), "deny"));
		}
	},

	async hint(asker, need, set, known, options) {
		if (need("direction")) {
			set(
				"direction",
				await asker.select("Who sends it?", [
					{ value: "ServerToClient", label: "The server, to clients" },
					{ value: "ClientToServer", label: "Clients, to the server" },
				]),
			);
		}
		if (need("target")) set("target", await asker.select("What is the hint about?", NETWORK_TARGET, OPTION_DEFAULTS.hint.target));
		if (need("mode")) {
			set(
				"mode",
				await asker.select("Which sends matter?", [
					{ value: "Pulse", label: "Every one", hint: "Pulse: each send is delivered" },
					{ value: "Latest", label: "Only the newest", hint: "Latest: older unsent values are dropped" },
				]),
			);
		}
		if (need("payloadFields")) set("payloadFields", await asker.fields("Does it carry any data?", "Add another payload field?"));
		if (need("authorize") && options.direction === "ClientToServer") {
			set("authorize", await asker.select("Which players may send it?", AUTHORIZATION.filter((policy) => policy.value !== "OwnerActor" || options.target === "Actor"), "deny"));
		}
	},

	async domain(asker, need, set, known, options) {
		if (need("audience")) {
			set(
				"audience",
				await asker.select(
					"Which players receive it?",
					[
						{ value: "Owner", label: "Only the player who owns the Actor" },
						{ value: "All", label: "Every player" },
					],
					OPTION_DEFAULTS.domain.audience,
				),
			);
		}
		if (need("stateFields")) set("stateFields", await asker.fields("Does it replicate any state?", "Add another state field?"));
		if (need("events")) {
			set(
				"events",
				await asker.each("Does it send events, such as a combo finisher?", "Add another event?", async (entries) => {
					const taken = entries.map((entry) => entry.split("(")[0]);
					const id = await asker.text("Event ID", {
						placeholder: "Finisher",
						validate: (value) => ENTRY_PROBLEMS.id((value ?? "").trim()) ?? (taken.includes((value ?? "").trim()) ? "That event already exists." : undefined),
					});
					const fields = await asker.fields(`Does ${id} carry any data?`, `Add another ${id} field?`);
					return fields.length === 0 ? id : `${id}(${fields.join(",")})`;
				}),
			);
		}
		if (need("observe") && options.events.length === 0) set("observe", await asker.confirm("Will server code report changes as they happen? (adds an observe stub)"));
	},
};

const EMPTY_CATALOG = Object.freeze({ tag: [], resource: [], action: [], controller: [], lock: [], property: [] });

export async function promptForMissing(kind, given, context = {}) {
	const prompts = context.prompts ?? clack;
	const asker = createAsker(prompts);
	const input = { ...given, options: { ...given.options } };

	prompts.intro(CATALOGS[kind].script);

	if (input.name === undefined && input.id === undefined && input.output === undefined) {
		input.name = await asker.text("Name", { placeholder: "Example", validate: (value) => nameProblem(value ?? "") });
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
