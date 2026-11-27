export const REQUIRE_DESCENDANTS_FILE = "src/shared/RequireDescendants.luau";
export const ACTION_REQUESTS_FOLDER = "src/shared/ActionRequests";
export const ACTION_INPUT_POLICIES_FOLDER = "src/client/ActionInputPolicies";
export const ACTION_REQUIREMENTS_FOLDER = "src/shared/ActionRequirements";
export const ACTION_PREDICTION_POLICIES_FOLDER = "src/client/ActionPredictionPolicies";
export const MERGE_DESCENDANTS_FILE = "src/shared/MergeDescendants.luau";
export const LOADOUT_FILE = "src/client/Controls/Loadout.luau";
export const KEYBINDS_FILE = "src/client/Controls/Keybinds.luau";

const SERVER_START_FIELDS = Object.freeze([
	"hints",
	"commands",
	"controllers",
	"properties",
	"tags",
	"resources",
	"actions",
	"replicationDomains",
	"actionRequestSchemas",
	"actionControlAuthority",
]);

export const SERVER_STARTUP = Object.freeze({
	side: "Server",
	source: "src/server",
	file: "src/server/Startup.server.luau",
	fields: SERVER_START_FIELDS,
});

export const CLIENT_STARTUP = Object.freeze({
	side: "Client",
	source: "src/client",
	file: "src/client/Startup.client.luau",
	fields: Object.freeze(["actionRequestSchemas", "actionInputPolicies", "actionPredictionPolicies", "presentations"]),
});

export const PRESENTATION_EVENTS = Object.freeze([
	"Action.Started",
	"Action.Ended",
	"Action.Interrupted",
	"Tag.Added",
	"Tag.Refreshed",
	"Tag.Removed",
	"Tag.Expired",
	"Resource.Changed",
	"Hint.Received",
]);

const catalog = (entry, startup = SERVER_STARTUP) =>
	Object.freeze({ idField: "id", ...entry, startup, defaultFolder: `${startup.source}/${entry.folder}` });

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
	property: catalog({
		kind: "property",
		script: "createProperty",
		label: "Property",
		field: "properties",
		folder: "Properties",
		type: "PropertyDefinition",
		variable: "properties",
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
	presentation: catalog(
		{
			kind: "presentation",
			script: "createPresentation",
			label: "Presentation",
			field: "presentations",
			folder: "Presentations",
			type: "PresentationDefinition",
			variable: "presentations",
		},
		CLIENT_STARTUP,
	),
});

export const KINDS = Object.freeze(Object.keys(CATALOGS));

export const BUILT_IN_CONTROLLER_KEYS = Object.freeze(["TagController", "PropertyController", "ResourceController", "ActionController"]);

export const BUILT_IN_PROPERTY_IDS = Object.freeze(["WalkSpeed", "JumpPower"]);

export const DEFINITION_SCRIPTS = Object.freeze(Object.fromEntries(KINDS.map((kind) => [CATALOGS[kind].script, `krf-tools create ${kind}`])));
