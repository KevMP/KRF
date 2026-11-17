import assert from "node:assert/strict";
import test from "node:test";

import { PROJECT_OPTION_DEFAULTS, projectOptionsSchema } from "../src/index.js";

test("the defaults are valid project options", () => {
	assert.deepEqual(projectOptionsSchema.parse(PROJECT_OPTION_DEFAULTS), PROJECT_OPTION_DEFAULTS);
});

test("rejects unsupported values and unknown options", () => {
	assert.equal(projectOptionsSchema.safeParse({ ...PROJECT_OPTION_DEFAULTS, mode: "studio" }).success, false);
	assert.equal(projectOptionsSchema.safeParse({ ...PROJECT_OPTION_DEFAULTS, extra: true }).success, false);
});
