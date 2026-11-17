export const SERVER_SOURCE = "src/server";
export const STARTUP_FILE = "src/server/Startup.server.luau";
export const REQUIRE_DESCENDANTS_FILE = "src/shared/RequireDescendants.luau";
export const ACTION_REQUESTS_FOLDER = "src/shared/ActionRequests";
export const ACTION_INPUT_POLICIES_FOLDER = "src/client/ActionInputPolicies";
export const LOADOUT_FILE = "src/client/Controls/Loadout.luau";
export const KEYBINDS_FILE = "src/client/Controls/Keybinds.luau";

export const SERVER_START_FIELDS = Object.freeze([
	"hints",
	"commands",
	"controllers",
	"tags",
	"resources",
	"actions",
	"replicationDomains",
	"actionRequestSchemas",
	"actionControlAuthority",
]);

const catalog = (entry) => Object.freeze({ idField: "id", ...entry, defaultFolder: `${SERVER_SOURCE}/${entry.folder}` });

export const CATALOGS = Object.freeze({
	action: catalog({ kind: "action", script: "createAction", label: "Action", field: "actions", folder: "Actions", type: "ActionFactory", variable: "actions" }),
	tag: catalog({ kind: "tag", script: "createTag", label: "Tag", field: "tags", folder: "Tags", type: "TagDefinition", variable: "tags" }),
	resource: catalog({
		kind: "resource",
		script: "createResource",
		label: "Resource",
		field: "resources",
		folder: "Resources",
		type: "ResourceDefinition",
		variable: "resources",
	}),
	controller: catalog({
		kind: "controller",
		script: "createController",
		label: "Controller",
		field: "controllers",
		folder: "Controllers",
		type: "ControllerDefinition",
		variable: "controllers",
		idField: "key",
	}),
	command: catalog({ kind: "command", script: "createCommand", label: "Command", field: "commands", folder: "Commands", type: "CommandDefinition", variable: "commands" }),
	hint: catalog({ kind: "hint", script: "createHint", label: "Hint", field: "hints", folder: "Hints", type: "HintDefinition", variable: "hints" }),
	domain: catalog({
		kind: "domain",
		script: "createDomain",
		label: "Replication domain",
		field: "replicationDomains",
		folder: "ReplicationDomains",
		type: "ReplicationDomainDefinition",
		variable: "replicationDomains",
	}),
});

export const KINDS = Object.freeze(Object.keys(CATALOGS));

export const BUILT_IN_CONTROLLER_KEYS = Object.freeze(["TagController", "PropertyController", "ResourceController", "ActionController"]);

export const DEFINITION_SCRIPTS = Object.freeze(Object.fromEntries(KINDS.map((kind) => [CATALOGS[kind].script, `krf-tools create ${kind}`])));
