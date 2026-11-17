import assert from "node:assert/strict";
import test from "node:test";

import { normalizeRequest } from "../src/generate/request.js";

const usage = (code) => ({ code, exitCode: 2 });

const ACTION_DEFAULTS = {
	recipe: "instant",
	duration: undefined,
	requestable: false,
	autoGrant: false,
	visibility: "ServerOnly",
	requiredTags: [],
	blockedTags: [],
	activeTags: [],
	appliedTags: [],
	requirements: [],
	costs: [],
	locks: [],
	interruptibleBy: [],
	hooks: [],
	startFields: [],
	stopFields: [],
	clientStop: false,
	allowInputInterrupt: false,
};

test("the name is the ID, and a namespaced ID nests the default path without changing the name", () => {
	assert.deepEqual(normalizeRequest("tag", { name: "Stunned" }), {
		kind: "tag",
		name: "Stunned",
		id: "Stunned",
		namespace: [],
		output: undefined,
		options: { visibility: "ServerOnly", duplicateBehavior: "Ignore", properties: [] },
	});

	const namespaced = normalizeRequest("action", { id: "Combat.Fireball" });
	assert.equal(namespaced.name, "Fireball");
	assert.deepEqual(namespaced.namespace, ["Combat"]);

	const renamed = normalizeRequest("action", { name: "Fireball", id: "Combat.FireballV2" });
	assert.deepEqual([renamed.name, renamed.id], ["Fireball", "Combat.FireballV2"]);
});

test("--output names the module and must stay inside a source folder", () => {
	const request = normalizeRequest("action", { output: "src\\server\\Actions\\Combat\\Fireball.luau" });
	assert.deepEqual([request.name, request.output], ["Fireball", "src/server/Actions/Combat/Fireball.luau"]);
	assert.equal(normalizeRequest("action", { output: "./src/server/Actions/Fireball.luau" }).output, "src/server/Actions/Fireball.luau");

	for (const [output, code] of [
		["../src/server/Actions/Fireball.luau", "UnsafeOutputPath"],
		["src/server/../../Fireball.luau", "UnsafeOutputPath"],
		["/src/server/Fireball.luau", "UnsafeOutputPath"],
		["C:\\game\\src\\server\\Fireball.luau", "UnsafeOutputPath"],
		["src/server/CON/Fireball.luau", "UnsafeOutputPath"],
		["src/server/Bad:Name/Fireball.luau", "UnsafeOutputPath"],
		["lib/server/Fireball.luau", "OutputOutsideSource"],
		["src/Fireball.luau", "OutputOutsideSource"],
		["src/server/Actions/Fireball.lua", "OutputOutsideSource"],
		["src/server/Actions/Fireball.server.luau", "InvalidName"],
		["src/server/Actions/init.luau", "InvalidName"],
	]) {
		assert.throws(() => normalizeRequest("action", { output }), usage(code), output);
	}

	assert.throws(() => normalizeRequest("action", { name: "Frostbolt", output: "src/server/Actions/Fireball.luau" }), usage("NameOutputMismatch"));
});

test("rejects unusable names and IDs, KRF's reserved IDs and built-in controller keys", () => {
	assert.throws(() => normalizeRequest("action", {}), usage("NameMissing"));
	for (const name of ["fireball", "Fire Ball", "Fire-Ball", "Fire.Ball", "KRF", "DURATION", "Con", "LPT1", "A".repeat(65), ""]) {
		assert.throws(() => normalizeRequest("action", { name }), usage("InvalidName"), name);
	}
	assert.throws(() => normalizeRequest("action", { id: "combat.fireball" }), usage("InvalidName"));
	for (const id of ["Combat..Fireball", ".Fireball", "Combat.", "1Fireball", "Combat/Fireball", "Combat.Nul.Fireball", "A".repeat(97)]) {
		assert.throws(() => normalizeRequest("action", { name: "Fireball", id }), usage("InvalidId"), id);
	}
	for (const id of ["KRF", "KRF.Tags", "KRF.Action.Start"]) {
		assert.throws(() => normalizeRequest("command", { name: "Example", id }), usage("IdReserved"), id);
	}
	assert.throws(() => normalizeRequest("controller", { name: "TagController" }), usage("IdReserved"));
});

test("Action options normalize to explicit values", () => {
	assert.deepEqual(normalizeRequest("action", { name: "Fireball" }).options, ACTION_DEFAULTS);

	const options = normalizeRequest("action", {
		name: "Fireball",
		options: {
			recipe: "channel",
			requestable: true,
			activeTags: ["Casting", "Burning:2.5"],
			appliedTags: ["Scorched:4"],
			requirements: ["Mana:maxPercent=1,min=10"],
			costs: ["Mana=10", "Combat.Rage:percent=0.5,multiplierProperty=RageCost"],
			hooks: ["onEnd", "onCanStart"],
			startFields: ["Target:Optional(U32),Element:Enum(Fire|Ice)"],
			onDisconnect: "Interrupt",
		},
	}).options;

	assert.equal(options.duration, 1);
	assert.equal(options.visibility, "ClientVisible");
	assert.deepEqual(options.activeTags, [{ id: "Casting" }, { id: "Burning", duration: 2.5 }]);
	assert.deepEqual(options.appliedTags, [{ id: "Scorched", duration: 4 }]);
	assert.deepEqual(options.requirements, [{ resource: "Mana", requirement: { min: 10, maxPercent: 1 } }]);
	assert.deepEqual(options.costs, [
		{ resource: "Mana", cost: { amount: 10 } },
		{ resource: "Combat.Rage", cost: { percent: 0.5, multiplierProperty: "RageCost" } },
	]);
	assert.deepEqual(options.hooks, ["onEnd", "onCanStart"]);
	assert.deepEqual(options.startFields, [
		{ name: "Target", type: { kind: "Optional", inner: { kind: "U32" } } },
		{ name: "Element", type: { kind: "Enum", values: ["Fire", "Ice"] } },
	]);
	assert.equal(normalizeRequest("action", { name: "Fireball", options: { recipe: "channel", duration: "0.5" } }).options.duration, 0.5);
});

test("a requestable Action can stay ServerOnly, and a client Stop always gets an onStopRequested handler", () => {
	assert.equal(normalizeRequest("action", { name: "Fireball", options: { requestable: true, visibility: "ServerOnly" } }).options.visibility, "ServerOnly");

	const stoppable = normalizeRequest("action", { name: "Fireball", options: { recipe: "channel", requestable: true, clientStop: true, hooks: ["onEnd"] } }).options;
	assert.equal(stoppable.clientStop, true);
	assert.deepEqual(stoppable.hooks, ["onEnd", "onStopRequested"]);

	const byParameters = normalizeRequest("action", { name: "Fireball", options: { requestable: true, stopFields: ["Reason:U8"] } }).options;
	assert.deepEqual([byParameters.clientStop, byParameters.hooks], [true, ["onStopRequested"]]);

	const held = normalizeRequest("action", { name: "Guard", options: { recipe: "held", requestable: true } }).options;
	assert.deepEqual([held.clientStop, held.hooks], [false, []]);
});

test("Tag, Resource and networking options parse property modifiers, numeric sources and schemas", () => {
	assert.deepEqual(
		normalizeRequest("tag", {
			name: "Burning",
			options: { duplicateBehavior: "Stack", maxStacks: "5", tickInterval: "0.5", properties: ["WalkSpeed:min=4,multiply=0.5", "JumpPower:set=0"] },
		}).options,
		{
			visibility: "ServerOnly",
			duplicateBehavior: "Stack",
			maxStacks: 5,
			tickInterval: 0.5,
			properties: [
				{ property: "WalkSpeed", modifier: { multiply: 0.5, min: 4 } },
				{ property: "JumpPower", modifier: { set: 0 } },
			],
		},
	);

	assert.deepEqual(normalizeRequest("resource", { name: "Mana", options: { max: "MaxMana=100", min: "5", regen: "ManaRegen=2" } }).options, {
		max: { propertyName: "MaxMana", defaultBaseValue: 100 },
		min: { value: 5 },
		initial: 100,
		regen: { propertyName: "ManaRegen", defaultBaseValue: 2 },
		visibility: "ServerOnly",
		autoAssign: true,
	});

	const domain = normalizeRequest("domain", { name: "ComboState", options: { stateFields: ["Count:U8"], events: ["Finisher(Damage:U16)", "Reset"] } }).options;
	assert.equal(domain.observe, true);
	assert.deepEqual(domain.events, [
		{ id: "Finisher", fields: [{ name: "Damage", type: { kind: "U16" } }] },
		{ id: "Reset", fields: [] },
	]);

	assert.deepEqual(normalizeRequest("command", { name: "CastSpell", options: { requestFields: ["Slots:Array(U8,4)", "Names:Map(String(8),Boolean,2)"] } }).options.requestFields, [
		{ name: "Slots", type: { kind: "Array", element: { kind: "U8" }, maxLength: 4 } },
		{ name: "Names", type: { kind: "Map", key: { kind: "String", maxBytes: 8 }, value: { kind: "Boolean" }, maxEntries: 2 } },
	]);
});

test("rejects contradictory or malformed options with the flag that caused them", () => {
	const cases = [
		["action", { duration: "2" }, /--duration applies only to the channel recipe/],
		["action", { recipe: "channel", duration: "0" }, /Invalid --duration/],
		["action", { recipe: "toggle" }, /Invalid --recipe/],
		["action", { costs: ["Mana"] }, /Invalid --cost/],
		["action", { costs: ["Mana=-1"] }, /Invalid --cost: Mana: the cost must be positive/],
		["action", { costs: ["Mana:amount=1,percent=0.5"] }, /exactly one of amount or percent/],
		["action", { costs: ["Mana=1", "Mana=2"] }, /'Mana' has more than one cost/],
		["action", { requirements: ["Mana:minPercent=2"] }, /between 0 and 1/],
		["action", { requirements: ["Mana:min=5,max=1"] }, /min is greater than max/],
		["action", { requirements: ["Mana:above=1"] }, /Invalid --requirement/],
		["action", { activeTags: ["Burning:soon"] }, /Invalid --active-tag/],
		["action", { blockedTags: ["Stunned", "Stunned"] }, /Invalid --blocked-tag: 'Stunned' is listed twice/],
		["action", { hooks: ["onDance"] }, /Invalid --hook/],
		["action", { hooks: ["onStart"] }, /instant recipe already writes onStart/],
		["action", { startFields: ["Target:U32"] }, /--start-field describes the client request, so it needs --requestable/],
		["action", { requestable: true, startFields: ["Target:U33"] }, /Invalid --start-field: 'U33' is not a schema type/],
		["action", { requestable: true, startFields: ["Target:Array(U8)"] }, /Array takes a type and a maximum length/],
		["action", { requestable: true, startFields: ["A:U8", "A:U16"] }, /'A' is listed twice/],
		["action", { requestable: true, recipe: "held", onDisconnect: "Keep" }, /disconnect must interrupt it/],
		["tag", { duplicateBehavior: "Merge" }, /Invalid --duplicate-behavior/],
		["tag", { maxStacks: "3" }, /--max-stacks needs --duplicate-behavior Stack/],
		["tag", { duplicateBehavior: "Stack", maxStacks: "1.5" }, /Invalid --max-stacks/],
		["tag", { properties: ["WalkSpeed:set=0,add=1"] }, /set cannot be combined/],
		["tag", { properties: ["WalkSpeed:add=1", "WalkSpeed:multiply=2"] }, /'WalkSpeed' is modified twice/],
		["resource", { max: "10", initial: "11" }, /--initial 11 is greater than the maximum 10/],
		["resource", { max: "10", min: "20" }, /The minimum 20 is greater than the maximum 10/],
		["resource", { regen: "-1" }, /--regen cannot be negative/],
		["resource", { max: "Max Mana=10" }, /Invalid --max/],
		["controller", { dependsOn: ["Example"] }, /cannot depend on itself/],
		["command", { target: "None", authorize: "OwnerActor" }, /OwnerActor needs --target Actor/],
		["hint", { direction: "Both" }, /Invalid --direction/],
		["hint", { authorize: "AnyReadyClient" }, /--authorize applies only to ClientToServer Hints/],
		["domain", { audience: "Team" }, /Invalid --audience/],
		["domain", { events: ["Hit", "Hit(Damage:U8)"] }, /the event 'Hit' is listed twice/],
	];

	for (const [kind, options, message] of cases) {
		assert.throws(() => normalizeRequest(kind, { name: "Example", options }), { exitCode: 2, message }, `${kind} ${JSON.stringify(options)}`);
	}
});

test("the other kinds default to private, deny-by-default shapes", () => {
	assert.deepEqual(normalizeRequest("resource", { name: "Stamina" }).options, { max: { value: 100 }, initial: 100, visibility: "ServerOnly", autoAssign: true });
	assert.deepEqual(normalizeRequest("controller", { name: "Cooldowns" }).options, { dependsOn: [], autoAttach: true });
	assert.deepEqual(normalizeRequest("command", { name: "CastSpell" }).options, { target: "Actor", requestFields: [], resultFields: [], authorize: "deny" });
	assert.deepEqual(normalizeRequest("hint", { name: "ImpactFx" }).options, { direction: "ServerToClient", target: "Actor", mode: "Pulse", payloadFields: [], authorize: "deny" });
	assert.deepEqual(normalizeRequest("domain", { name: "ComboState" }).options, { audience: "Owner", stateFields: [], events: [], observe: false });
});
