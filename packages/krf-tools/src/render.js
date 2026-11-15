// Renders bundled template directories into memory with mem-fs-editor. Nothing touches the
// destination until the caller writes the returned file set.
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { create as createStore } from "mem-fs";
import { create as createEditor } from "mem-fs-editor";

import { KrfToolError } from "./errors.js";

const PLACEHOLDER = /__([A-Za-z][A-Za-z0-9]*)__/g;

function listFiles(root) {
	return fs
		.readdirSync(root, { recursive: true, withFileTypes: true })
		.filter((entry) => entry.isFile())
		.map((entry) => path.relative(root, path.join(entry.parentPath, entry.name)).split(path.sep).join("/"))
		.sort();
}

/**
 * Maps a template-relative path to its output path:
 * `.ejs` is removed from rendered files, `__key__` segments are replaced from `data`,
 * and a leading `_` on a name becomes `.` (npm drops `.gitignore` from published packages).
 * @param {string} templatePath
 * @param {Record<string, unknown>} data
 */
export function outputPath(templatePath, data) {
	const withoutSuffix = templatePath.endsWith(".ejs") ? templatePath.slice(0, -".ejs".length) : templatePath;

	return withoutSuffix
		.split("/")
		.map((segment) => {
			const substituted = segment.replace(PLACEHOLDER, (_, key) => {
				const value = data[key];
				if (typeof value !== "string" || value === "") {
					throw new KrfToolError("TemplateValueMissing", `Template path '${templatePath}' needs a value for '${key}'.`);
				}
				return value;
			});
			return substituted.startsWith("_") ? `.${substituted.slice(1)}` : substituted;
		})
		.join("/");
}

/**
 * Renders template directories in order; a later directory may replace an earlier file.
 * `.ejs` files are rendered as EJS with `data`; every other file is copied byte-for-byte.
 * @param {string[]} templateRoots
 * @param {Record<string, unknown>} data
 * @returns {Map<string, Buffer>} Output path to contents, in sorted path order.
 */
export function renderTemplates(templateRoots, data) {
	const store = createStore();
	const editor = createEditor(store);
	const virtualRoot = path.join(os.tmpdir(), `krf-render-${randomUUID()}`);
	const outputs = new Set();

	for (const root of templateRoots) {
		for (const templatePath of listFiles(root)) {
			const source = path.join(root, templatePath);
			const relative = outputPath(templatePath, data);
			const destination = path.join(virtualRoot, relative);

			if (templatePath.endsWith(".ejs")) {
				editor.copyTpl(source, destination, data);
			} else {
				editor.copy(source, destination);
			}
			outputs.add(relative);
		}
	}

	const files = new Map();
	for (const relative of [...outputs].sort()) {
		const contents = editor.read(path.join(virtualRoot, relative), { raw: true });
		files.set(relative, Buffer.from(contents));
	}

	return files;
}
