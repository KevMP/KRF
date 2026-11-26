import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const PACKAGE_ROOT = fileURLToPath(new URL("../", import.meta.url));

export const REFERENCE_DOCS = path.resolve(PACKAGE_ROOT, "../../docs-site/docs/reference");
export const SKILL_DOCS = path.join(PACKAGE_ROOT, "templates/agents/_agents/skills/krf/references/docs");
export const DOCS_SITE_URL = "https://kevmp.github.io/KRF";

const FRONTMATTER = /^---\r?\n[\s\S]*?\r?\n---\r?\n+/;
const LINK = /\]\(([^)\s]+)\)/g;
const FENCE = /^\s*(```|~~~)/;

function markdownFiles(root) {
	return fs
		.readdirSync(root, { recursive: true, withFileTypes: true })
		.filter((entry) => entry.isFile() && entry.name.endsWith(".md"))
		.map((entry) => path.relative(root, path.join(entry.parentPath, entry.name)).split(path.sep).join("/"))
		.sort();
}

function pagePath(sitePath) {
	if (sitePath === "" || sitePath.endsWith("/")) return `${sitePath}index.md`;
	return path.posix.extname(sitePath) === "" ? `${sitePath}.md` : sitePath;
}

export function rewriteLink(target, file) {
	if (/^[a-z][a-z0-9+.-]*:/i.test(target) || target.startsWith("#")) return target;

	const hash = target.indexOf("#");
	const location = hash === -1 ? target : target.slice(0, hash);
	const anchor = hash === -1 ? "" : target.slice(hash);
	const directory = path.posix.join("/reference", path.posix.dirname(file));
	const joined = location.startsWith("/") ? location : path.posix.join(directory, location);
	const site = location.endsWith("/") && !joined.endsWith("/") ? `${joined}/` : joined;

	if (site !== "/reference" && !site.startsWith("/reference/")) return `${DOCS_SITE_URL}${site}${anchor}`;

	const page = pagePath(site === "/reference" ? "" : site.slice("/reference/".length));
	const relative = path.posix.relative(path.posix.dirname(file), page);
	return `${relative.startsWith(".") ? relative : `./${relative}`}${anchor}`;
}

export function rewriteDocument(contents, file) {
	let fenced = false;

	return contents
		.replace(FRONTMATTER, "")
		.split("\n")
		.map((line) => {
			if (FENCE.test(line)) {
				fenced = !fenced;
				return line;
			}
			if (fenced) return line;
			return line
				.split(/(`[^`]*`)/)
				.map((part) => (part.startsWith("`") ? part : part.replace(LINK, (_, target) => `](${rewriteLink(target, file)})`)))
				.join("");
		})
		.join("\n");
}

export function copySkillDocs({ source = REFERENCE_DOCS, destination = SKILL_DOCS } = {}) {
	fs.rmSync(destination, { recursive: true, force: true });

	for (const file of markdownFiles(source)) {
		const output = path.join(destination, file);
		fs.mkdirSync(path.dirname(output), { recursive: true });
		fs.writeFileSync(output, rewriteDocument(fs.readFileSync(path.join(source, file), "utf8"), file));
	}
}

export function removeSkillDocs({ destination = SKILL_DOCS } = {}) {
	fs.rmSync(destination, { recursive: true, force: true });
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
	if (process.argv.includes("--clean")) removeSkillDocs();
	else copySkillDocs();
}
