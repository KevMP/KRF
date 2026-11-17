import { Command, CommanderError, Option } from "commander";

import { TOOLS_PACKAGE, TOOLS_VERSION } from "../compatibility.js";
import { ExitCode, KrfToolError, formatError } from "../errors.js";
import { applyProjectChanges } from "../files.js";
import { CATALOGS, KINDS } from "./catalogs.js";
import { createConsumer, findProjectRoot, readKrfDependency } from "./consumer.js";
import { planGeneration, projectCatalog } from "./plan.js";
import { promptForMissing } from "./prompts.js";
import { errorResult, exitCodeOf, formatResult, resultOf } from "./report.js";
import { ACTION_HOOKS, normalizeRequest } from "./request.js";
import { SCHEMA_TYPES_HELP } from "./schema.js";

const VISIBILITY = { flags: "--visibility <visibility>", description: "ServerOnly or ClientVisible (default: ServerOnly)", key: "visibility" };
const TARGET = { flags: "--target <target>", description: "Actor or None (default: Actor)", key: "target" };
const AUTHORIZE = {
	flags: "--authorize <policy>",
	description: "deny, OwnerActor or AnyReadyClient; the built-in policies come from KRF (default: deny)",
	key: "authorize",
};
const repeat = (flags, description, key) => ({ flags, description: `${description} (repeatable)`, key, repeatable: true });
const field = (flags, what, key) => repeat(flags, `a field of the ${what}, such as Amount:U8; types are ${SCHEMA_TYPES_HELP}`, key);

const KIND_OPTIONS = {
	action: [
		{ flags: "--recipe <recipe>", description: "instant, channel or held (default: instant)", key: "recipe" },
		{ flags: "--duration <seconds>", description: "how long the channel recipe runs (default: 1)", key: "duration" },
		{ flags: "--auto-grant", description: "grant it to every Actor", key: "autoGrant" },
		{ ...VISIBILITY, description: "ServerOnly or ClientVisible (default: ServerOnly; ClientVisible with --requestable)" },
		repeat("--required-tag <TagId>", "a Tag the Actor must have to start it", "requiredTags"),
		repeat("--blocked-tag <TagId>", "a Tag that stops it from starting", "blockedTags"),
		repeat("--active-tag <TagId[:seconds]>", "a Tag the Action holds while it runs", "activeTags"),
		repeat("--applied-tag <TagId[:seconds]>", "a Tag the Action applies that outlives it", "appliedTags"),
		repeat("--requirement <Resource:min=..,max=..,minPercent=..,maxPercent=..>", "a Resource condition checked before it starts", "requirements"),
		repeat("--cost <Resource=amount | Resource:percent=..,multiplierProperty=..>", "a Resource cost paid when it starts", "costs"),
		repeat("--lock <LockId>", "a lock held while it runs", "locks"),
		repeat("--interruptible-by <ActionId>", "an Action allowed to preempt it when locks conflict", "interruptibleBy"),
		repeat("--hook <hook>", `an extra lifecycle hook stub: ${ACTION_HOOKS.join(", ")}`, "hooks"),
		{ flags: "--requestable", description: "let clients request it: creates its module in src/shared/ActionRequests", key: "requestable" },
		field("--start-field <Name:Type>", "client's start parameters", "startFields"),
		field("--stop-field <Name:Type>", "client's stop parameters", "stopFields"),
		{ flags: "--client-stop", description: "let the client request a Stop (held Actions always can)", key: "clientStop" },
		{ flags: "--allow-input-interrupt", description: "let the client interrupt its own activation", key: "allowInputInterrupt" },
		{ flags: "--on-disconnect <policy>", description: "Keep or Interrupt when the requesting player leaves (held Actions always interrupt)", key: "onDisconnect" },
	],
	tag: [
		VISIBILITY,
		{ flags: "--duplicate-behavior <behavior>", description: "Ignore, Refresh or Stack (default: Ignore)", key: "duplicateBehavior" },
		{ flags: "--max-stacks <count>", description: "the most instances a Stack Tag can have; omit for no limit", key: "maxStacks" },
		{ flags: "--duration <seconds>", description: "default duration; omit for a Tag that lasts until removed", key: "duration" },
		{ flags: "--tick-interval <seconds>", description: "run onTick every interval while the Tag is active", key: "tickInterval" },
		repeat("--property <Property:operation=value>", "a property modifier, such as WalkSpeed:multiply=0.5,min=4; operations are set, add, multiply, min and max", "properties"),
	],
	resource: [
		{ flags: "--max <value | Property>", description: "maximum: a number, or a registered Property ID (default: 100)", key: "max" },
		{ flags: "--min <value | Property>", description: "minimum: a number, or a registered Property ID (default: 0)", key: "min" },
		{ flags: "--initial <value>", description: "starting value (default: the maximum)", key: "initial" },
		{ flags: "--regen <rate | Property>", description: "regeneration per second: a number, or a registered Property ID", key: "regen" },
		VISIBILITY,
		{ flags: "--no-auto-assign", description: "do not give it to every Actor", key: "autoAssign" },
	],
	property: [
		{ flags: "--default <value>", description: "the default base value on every Actor that has it (default: 0)", key: "defaultBaseValue" },
		{ flags: "--auto-assign", description: "give it to every Actor", key: "autoAssign" },
	],
	controller: [
		repeat("--depends-on <key>", "a controller key it needs attached first", "dependsOn"),
		{ flags: "--no-auto-attach", description: "do not attach it to every Actor", key: "autoAttach" },
	],
	command: [TARGET, field("--request-field <Name:Type>", "request", "requestFields"), field("--result-field <Name:Type>", "result", "resultFields"), AUTHORIZE],
	hint: [
		{ flags: "--direction <direction>", description: "ServerToClient or ClientToServer (default: ServerToClient)", key: "direction" },
		TARGET,
		{ flags: "--mode <mode>", description: "Pulse or Latest (default: Pulse)", key: "mode" },
		field("--payload-field <Name:Type>", "payload", "payloadFields"),
		{ ...AUTHORIZE, description: `${AUTHORIZE.description}; ClientToServer only` },
	],
	domain: [
		{ flags: "--audience <audience>", description: "Owner or All (default: Owner)", key: "audience" },
		field("--state-field <Name:Type>", "replicated state", "stateFields"),
		repeat("--event <EventId[(Name:Type,...)]>", "a replicated event, such as Hit(Damage:U16); adds an observe stub", "events"),
		{ flags: "--observe", description: "add an observe stub that reports committed changes", key: "observe" },
	],
};

const EXAMPLES = {
	action: "--name Fireball --recipe channel --duration 2 --cost Mana=10 --active-tag Casting --requestable --yes",
	tag: "--name Slowed --duration 3 --property WalkSpeed:multiply=0.5 --yes",
	resource: "--name Stamina --max MaxStamina --regen 5 --yes",
	property: "--name MaxStamina --default 100 --auto-assign --yes",
	controller: "--name Cooldowns --depends-on ResourceController --yes",
	command: "--name CastSpell --request-field Slot:U8 --authorize OwnerActor --yes",
	hint: "--name ImpactFx --payload-field Position:Array(F32,3) --yes",
	domain: '--name ComboState --state-field Count:U8 --event "Finisher(Damage:U16)" --yes',
};

const collect = (value, previous = []) => [...previous, value];

function buildProgram(io, onSelect) {
	const program = new Command(TOOLS_PACKAGE)
		.description("KRF project tools. Run them through the project's npm scripts.")
		.version(TOOLS_VERSION, "-v, --version")
		.helpOption("-h, --help")
		.exitOverride()
		.showSuggestionAfterError(true)
		.configureOutput({ writeOut: io.stdout, writeErr: io.stderr });

	const create = program.command("create").description("Create a KRF definition module");

	for (const kind of KINDS) {
		const catalog = CATALOGS[kind];
		const command = create
			.command(kind)
			.description(`Create a ${catalog.label} module in ${catalog.defaultFolder}, which Startup.server.luau passes to KRF.Server.Init as ${catalog.field}.`)
			.option("--name <Name>", "PascalCase module name; also the ID unless --id is given")
			.option("--id <id>", `${catalog.idField === "key" ? "controller key" : "ID"}; may be namespaced, such as Combat.Example`)
			.option("--output <path>", "module path relative to the project root");

		const keys = new Map();
		for (const entry of KIND_OPTIONS[kind]) {
			const option = new Option(entry.flags, entry.description);
			if (entry.repeatable) option.argParser(collect);
			command.addOption(option);
			keys.set(option.attributeName(), entry.key);
		}

		command
			.option("--dry-run", "show what would change without writing anything")
			.option("--json", "print exactly one JSON result object to stdout")
			.option("-y, --yes", "use defaults for every value not given; never prompt")
			.addHelpText("after", `\nExample:\n  npm run ${catalog.script} -- ${EXAMPLES[kind]}\n`)
			.action(() => onSelect(kind, command, keys));
	}

	return program;
}

function inputFrom(command, keys) {
	const flags = command.opts();
	const options = {};
	for (const [attribute, key] of keys) {
		if (command.getOptionValueSource(attribute) === "cli") options[key] = flags[attribute];
	}
	return { name: flags.name, id: flags.id, output: flags.output, options };
}

function usageError(error) {
	return new KrfToolError("InvalidArguments", error.message.replace(/^error: /, ""), { exitCode: ExitCode.usage });
}

export async function runGenerator(argv, io) {
	const json = argv.includes("--json");
	let selected;
	const program = buildProgram(io, (kind, command, keys) => {
		selected = { kind, command, keys };
	});

	try {
		program.parse(argv, { from: "user" });
		const { kind, command, keys } = selected;
		const flags = command.opts();

		const root = findProjectRoot(io.cwd);
		const consumer = createConsumer(root);
		const krf = readKrfDependency(consumer);

		let input = inputFrom(command, keys);
		if (io.interactive && !flags.yes && !flags.json) input = await promptForMissing(kind, input, { prompts: io.prompts, known: projectCatalog(consumer) });

		const request = normalizeRequest(kind, input);
		const plan = planGeneration(consumer, request, krf.alias);
		if (!flags.dryRun && plan.status !== "already-exists") applyProjectChanges(root, plan.changes);

		const result = resultOf(plan, flags.dryRun === true);
		for (const warning of result.warnings) io.stderr(`warning: ${warning}\n`);
		io.stdout(flags.json ? `${JSON.stringify(result, null, 2)}\n` : formatResult(result));
		return exitCodeOf(result);
	} catch (error) {
		if (error instanceof CommanderError) {
			if (error.code === "commander.helpDisplayed" || error.code === "commander.version") return ExitCode.ok;
			if (json) io.stdout(`${JSON.stringify(errorResult(usageError(error)), null, 2)}\n`);
			return ExitCode.usage;
		}

		if (json) io.stdout(`${JSON.stringify(errorResult(error), null, 2)}\n`);
		io.stderr(`${formatError(error)}\n`);
		return error instanceof KrfToolError ? error.exitCode : ExitCode.failure;
	}
}
