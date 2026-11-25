import fs from "node:fs";
import path from "node:path";

import { KrfToolError } from "../errors.js";
import { spawnTool } from "../workflow/tools.js";
import { sourceState } from "./build.js";

const VERSION = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const BUMPS = ["major", "minor", "patch"];

export const releaseTag = (version) => `v${version}`;

function invalidVersion(version) {
	return new KrfToolError("invalid-version", `Use a MAJOR.MINOR.PATCH version in package.json, not ${JSON.stringify(version)}.`);
}

function parseVersion(text) {
	const version = JSON.parse(text).version;
	if (typeof version !== "string" || !VERSION.test(version)) throw invalidVersion(version);
	return version;
}

function readVersion(project) {
	return parseVersion(fs.readFileSync(path.join(project.root, "package.json"), "utf8"));
}

export function nextVersion(current, to) {
	const parts = VERSION.exec(current)?.slice(1).map(Number);
	if (!parts) throw invalidVersion(current);
	const bump = BUMPS.indexOf(to);
	if (bump !== -1) return parts.map((part, index) => index < bump ? part : index === bump ? part + 1 : 0).join(".");
	const exact = VERSION.exec(to ?? "")?.slice(1).map(Number);
	if (!exact) throw new KrfToolError("invalid-version", "Pass --to patch, --to minor, --to major or an exact MAJOR.MINOR.PATCH version.");
	const index = exact.findIndex((part, position) => part !== parts[position]);
	if (index === -1 || exact[index] < parts[index]) throw new KrfToolError("invalid-version", `${to} must be newer than the current version ${current}.`);
	return to;
}

function setVersion(file, version, lockfile) {
	const text = fs.readFileSync(file, "utf8");
	const indent = /^([ \t]+)"/m.exec(text)?.[1] ?? "  ";
	const value = JSON.parse(text);
	value.version = version;
	if (lockfile && value.packages?.[""]) value.packages[""].version = version;
	fs.writeFileSync(file, `${JSON.stringify(value, null, indent)}\n`);
}

function git(system, project, ...args) {
	const result = spawnTool(system, "git", args, { cwd: project.root });
	if (result.status !== 0) throw new KrfToolError("git-failed", `git ${args[0]} failed: ${`${result.stderr ?? ""}`.trim() || "no output"}.`);
	return `${result.stdout ?? ""}`.trim();
}

export async function openReleasePullRequest(system, project, github, to) {
	if (sourceState(system, project).dirty) throw new KrfToolError("dirty-worktree", "Open the release from a clean checkout of main.");
	const current = readVersion(project);
	if (current !== "0.0.0" && await github.tagCommit(releaseTag(current)) === undefined) {
		throw new KrfToolError("release-pending", `${releaseTag(current)} is on main but has no tag yet. Re-run the Release workflow on main before opening another release.`);
	}
	const version = nextVersion(current, to);
	const tag = releaseTag(version);
	if (await github.tagCommit(tag) !== undefined) throw new KrfToolError("release-exists", `${tag} is already tagged. Choose a newer version.`);
	const branch = `release/${tag}`;
	const title = `chore(release): ${tag}`;
	const files = ["package.json", "package-lock.json"].filter((file) => fs.existsSync(path.join(project.root, file)));
	git(system, project, "switch", "--create", branch);
	for (const file of files) setVersion(path.join(project.root, file), version, file === "package-lock.json");
	git(system, project, "add", "--", ...files);
	git(system, project, "commit", "--message", title);
	git(system, project, "push", "--set-upstream", "origin", branch);
	const url = await github.openPullRequest(branch, title, `Releases ${tag}. Merging tags the merge commit and deploys it to QA.`);
	return { status: "validated", version, tag, branch, url };
}

export async function tagRelease(system, project, github) {
	const source = sourceState(system, project);
	const version = readVersion(project);
	const tag = releaseTag(version);
	const previous = spawnTool(system, "git", ["show", "HEAD^:package.json"], { cwd: project.root });
	if (previous.status === 0 && parseVersion(previous.stdout) === version) return { status: "validated", released: false, version };
	const existing = await github.tagCommit(tag);
	if (existing !== undefined && existing !== source.commit) {
		throw new KrfToolError("release-exists", `${tag} already points at ${existing}. Release a newer version instead.`);
	}
	if (existing === undefined) await github.createTag(tag, source.commit);
	await github.dispatchDeploy(tag, "qa");
	return { status: "validated", released: true, version, tag, commit: source.commit, qa: "dispatched" };
}

export async function verifyProductionSource(system, project, env, github) {
	const source = sourceState(system, project);
	const tag = releaseTag(readVersion(project));
	if (env.GITHUB_REF !== `refs/tags/${tag}`) {
		throw new KrfToolError("release-tag-required", `Production deploys run from the release tag that matches package.json (${tag}). Choose that tag when you run the workflow.`);
	}
	if (source.dirty) throw new KrfToolError("dirty-worktree", "Production deploys need a clean checkout of the tag.");
	if (await github.tagCommit(tag) !== source.commit) throw new KrfToolError("release-tag-mismatch", `${tag} does not point at the checked-out commit.`);
	if (!await github.onMain(source.commit)) throw new KrfToolError("release-not-on-main", `${tag} is not on main. Release from main through a release pull request.`);
	if (!await github.qaDeployed(source.commit)) throw new KrfToolError("qa-not-deployed", `${tag} has not deployed to QA successfully. Deploy it to QA first.`);
	return { source, tag };
}
