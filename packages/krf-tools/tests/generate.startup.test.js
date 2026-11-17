import assert from "node:assert/strict";
import test from "node:test";

import { CATALOGS } from "../src/generate/catalogs.js";
import { addCatalog, readStartup, wiringOf } from "../src/generate/startup.js";

const STARTUP = `--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local ActionRequests = require(ReplicatedStorage.Shared.ActionRequests)
local Actions = require(script.Parent.Actions)
local PlayerActors = require(script.Parent.PlayerActors)
local Resources = require(script.Parent.Resources)
local Tags = require(script.Parent.Tags)

local started: boolean, failure: KRF.ServerStartupFailure? = KRF.Server.Init({
	tags = Tags,
	resources = Resources,
	actions = Actions,
	actionRequestSchemas = ActionRequests,
})

PlayerActors.Start()
`;

test("reads which folder each catalog field loads", () => {
	const startup = readStartup(STARTUP);
	assert.deepEqual(wiringOf(startup, "actions"), { state: "wired", folder: "src/server/Actions" });
	assert.deepEqual(wiringOf(startup, "controllers"), { state: "unwired" });
	assert.deepEqual(wiringOf(readStartup(STARTUP.replace("\tactions = Actions,", "\tactions = { Actions },")), "actions"), { state: "custom" });
	assert.deepEqual(wiringOf(readStartup(STARTUP.replace("script.Parent.Actions", "script.Parent.Game.Actions")), "actions"), { state: "wired", folder: "src/server/Game/Actions" });
	assert.deepEqual(wiringOf(readStartup("return nil\n"), "actions"), { state: "unknown" });
	assert.deepEqual(wiringOf(undefined, "actions"), { state: "unknown" });
});

test("adds a catalog's require in order and its field in ServerStartConfig order", () => {
	let source = STARTUP;
	for (const kind of ["domain", "controller", "hint", "command"]) source = addCatalog(readStartup(source), CATALOGS[kind]);

	assert.equal(
		source,
		STARTUP.replace(
			"local Actions = require(script.Parent.Actions)\n",
			"local Actions = require(script.Parent.Actions)\nlocal Commands = require(script.Parent.Commands)\nlocal Controllers = require(script.Parent.Controllers)\nlocal Hints = require(script.Parent.Hints)\n",
		)
			.replace("local PlayerActors = require(script.Parent.PlayerActors)\n", "local PlayerActors = require(script.Parent.PlayerActors)\nlocal ReplicationDomains = require(script.Parent.ReplicationDomains)\n")
			.replace("\ttags = Tags,", "\thints = Hints,\n\tcommands = Commands,\n\tcontrollers = Controllers,\n\ttags = Tags,")
			.replace("\tactions = Actions,\n", "\tactions = Actions,\n\treplicationDomains = ReplicationDomains,\n"),
	);
});

test("keeps CRLF line endings when it edits", () => {
	const edited = addCatalog(readStartup(STARTUP.replace(/\n/g, "\r\n")), CATALOGS.controller);
	assert.equal(edited, addCatalog(readStartup(STARTUP), CATALOGS.controller).replace(/\n/g, "\r\n"));
});

test("leaves customized startup code alone", () => {
	const customized = [
		STARTUP.replace("\tactions = Actions,\n", "\tactions = Actions,\n\tcontrollers = MyControllers,\n"),
		STARTUP.replace("\tactions = Actions,\n", "\tactions = Actions,\n\t-- more soon\n"),
		STARTUP.replace("\ttags = Tags,", "\ttags = Tags, -- statuses"),
		STARTUP.replace("})\n", "}) -- startup\n"),
		STARTUP.replace("local PlayerActors", "\nlocal PlayerActors"),
		STARTUP.replace("PlayerActors.Start()", "PlayerActors.Start()\nlocal Controllers = {}"),
		STARTUP.replace("KRF.Server.Init({", "KRF.Server.Init(config)\nKRF.Server.Init({"),
		STARTUP.replace("KRF.Server.Init({", "KRF.Server.Init(table.freeze({"),
		"return nil\n",
	];

	for (const source of customized) assert.equal(addCatalog(readStartup(source), CATALOGS.controller), undefined, source);
});
