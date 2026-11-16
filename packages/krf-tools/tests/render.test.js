import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { outputPath, renderTemplates } from "../src/index.js";

function templates(t, files) {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "krf-templates-"));
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	for (const [relative, contents] of Object.entries(files)) {
		fs.mkdirSync(path.dirname(path.join(root, relative)), { recursive: true });
		fs.writeFileSync(path.join(root, relative), contents);
	}
	return root;
}

test("renders .ejs files with the template data and drops the suffix", (t) => {
	const root = templates(t, { "README.md.ejs": "# <%= name %>\n<% if (ci) { %>CI<% } %>\n" });
	const files = renderTemplates([root], { name: "my-game", ci: true });
	assert.deepEqual([...files.keys()], ["README.md"]);
	assert.equal(files.get("README.md").toString(), "# my-game\nCI\n");
});

test("substitutes __key__ path segments and restores dotfiles named with a leading underscore", (t) => {
	const root = templates(t, { "src/__name__/init.luau": "return {}\n", _gitignore: "node_modules/\n", ".github/ci.yml": "on: push\n" });
	const files = renderTemplates([root], { name: "Fireball" });
	assert.deepEqual([...files.keys()], [".github/ci.yml", ".gitignore", "src/Fireball/init.luau"]);
});

test("copies non-template files byte for byte, including binary data", (t) => {
	const binary = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x00, 0xff, 0x0d, 0x0a, 0x3c, 0x25, 0x3d, 0x25, 0x3e]);
	const root = templates(t, { "assets/icon.png": binary, "notes.txt": "<%= untouched %>\r\n" });
	const files = renderTemplates([root], {});
	assert.deepEqual(files.get("assets/icon.png"), binary);
	assert.equal(files.get("notes.txt").toString(), "<%= untouched %>\r\n");
});

test("lets a later template directory replace a file from an earlier one", (t) => {
	const base = templates(t, { "a.txt": "base\n", "b.txt": "base\n" });
	const overlay = templates(t, { "b.txt": "overlay\n" });
	const files = renderTemplates([base, overlay], {});
	assert.equal(files.get("a.txt").toString(), "base\n");
	assert.equal(files.get("b.txt").toString(), "overlay\n");
});

test("fails before writing when a path placeholder has no value", () => {
	assert.throws(() => outputPath("src/__name__.luau", {}), { code: "TemplateValueMissing" });
	assert.throws(() => outputPath("src/__name__.luau", { name: "" }), { code: "TemplateValueMissing" });
});

test("fails when a template references undefined data", (t) => {
	const root = templates(t, { "README.md.ejs": "<%= missing %>" });
	assert.throws(() => renderTemplates([root], {}), /missing is not defined/);
});

test("produces identical output for identical input", (t) => {
	const root = templates(t, { "z.txt": "z", "a/b.txt.ejs": "<%= value %>", "m.txt": "m" });
	const first = renderTemplates([root], { value: 1 });
	const second = renderTemplates([root], { value: 1 });
	assert.deepEqual([...first.keys()], ["a/b.txt", "m.txt", "z.txt"]);
	assert.deepEqual(first, second);
});
