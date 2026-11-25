import { KrfToolError } from "../errors.js";

export const DEPLOY_WORKFLOW = "deploy.yml";
const API = "https://api.github.com";
const SHA = /^[a-f0-9]{40}$/;

function unavailable(message) {
	return new KrfToolError("github-unavailable", message, { hint: "Check the workflow's permissions and try again." });
}

export function githubClient(env, fetch = globalThis.fetch) {
	const repo = env.GITHUB_REPOSITORY;
	const token = env.KRF_GITHUB_TOKEN;
	if (!/^[\w.-]+\/[\w.-]+$/.test(repo ?? "") || !token) {
		throw new KrfToolError("github-required", "Run this command in the project's GitHub Actions workflow, which sets GITHUB_REPOSITORY and KRF_GITHUB_TOKEN.");
	}

	async function call(resource, { method = "GET", body } = {}) {
		const headers = { authorization: `Bearer ${token}`, accept: "application/vnd.github+json" };
		if (body !== undefined) headers["content-type"] = "application/json";
		let response;
		try {
			response = await fetch(`${API}/repos/${repo}${resource}`, {
				method, headers, body: body === undefined ? undefined : JSON.stringify(body), redirect: "error", signal: AbortSignal.timeout(30_000),
			});
		} catch {
			throw unavailable(`GitHub did not respond to ${method} ${resource}.`);
		}
		return { status: response.status, ok: response.ok, data: await response.json().catch(() => undefined) };
	}

	async function read(resource) {
		const result = await call(resource);
		if (!result.ok || result.data === undefined) throw unavailable(`GitHub could not read ${resource} (HTTP ${result.status}).`);
		return result.data;
	}

	async function write(resource, body, expected) {
		const result = await call(resource, { method: "POST", body });
		if (result.status !== expected) throw unavailable(`GitHub refused POST ${resource} (HTTP ${result.status}).`);
		return result.data;
	}

	return {
		repo,

		async onMain(commit) {
			const comparison = await read(`/compare/${commit}...main`);
			return comparison.status === "ahead" || comparison.status === "identical";
		},

		async qaDeployed(commit) {
			const runs = await read(`/actions/workflows/${DEPLOY_WORKFLOW}/runs?head_sha=${commit}&status=completed&per_page=100`);
			for (const run of runs.workflow_runs ?? []) {
				if (run.head_sha !== commit) continue;
				const jobs = await read(`/actions/runs/${run.id}/jobs?per_page=100`);
				if (jobs.jobs?.some((job) => job.name === "qa" && job.conclusion === "success")) return true;
			}
			return false;
		},

		async tagCommit(tag) {
			const result = await call(`/git/ref/tags/${tag}`);
			if (result.status === 404) return undefined;
			if (!result.ok || !result.data?.object) throw unavailable(`GitHub could not read the tag ${tag} (HTTP ${result.status}).`);
			let object = result.data.object;
			if (object.type === "tag") object = (await read(`/git/tags/${object.sha}`)).object;
			if (object?.type !== "commit" || !SHA.test(object.sha ?? "")) throw unavailable(`The tag ${tag} does not point at a commit.`);
			return object.sha;
		},

		async createTag(tag, commit) {
			await write("/git/refs", { ref: `refs/tags/${tag}`, sha: commit }, 201);
		},

		async dispatchDeploy(ref, target) {
			await write(`/actions/workflows/${DEPLOY_WORKFLOW}/dispatches`, { ref, inputs: { target } }, 204);
		},

		async openPullRequest(head, title, body) {
			const pull = await write("/pulls", { title, head, base: "main", body }, 201);
			if (typeof pull?.html_url !== "string") throw unavailable("GitHub did not return the pull request link.");
			return pull.html_url;
		},
	};
}
