import { setTimeout as wait } from "node:timers/promises";

import { KrfToolError } from "../errors.js";
import { isId } from "./config.js";

export const ORIGIN = "https://apis.roblox.com";
const OPERATION = /^operations\/[A-Za-z0-9_-]+$/;
const REJECTED = new Set([400, 401, 403, 404, 405, 413, 415, 422, 429]);
export const PLACE_PUBLISHER = "roblox-assets-v1-place";
export const MAX_PLACE_BYTES = 20_000_000;

export function multipart(metadata, bytes, type, name) {
	const body = new FormData();
	body.set("request", JSON.stringify(metadata));
	body.set("fileContent", new Blob([bytes], { type }), name);
	return body;
}

function robloxError(data) {
	const error = Array.isArray(data?.errors) ? data.errors[0] : data;
	if (!error || typeof error !== "object") return undefined;
	const reason = Array.isArray(error.details) ? error.details.find((detail) => /^[A-Za-z]{1,80}$/.test(detail?.reason ?? ""))?.reason : undefined;
	const message = typeof error.message === "string" && error.message.trim() ? error.message.trim().slice(0, 300) : undefined;
	const code = ["string", "number"].includes(typeof error.code) ? String(error.code).slice(0, 40) : undefined;
	return message || reason || code ? { code, message, reason } : undefined;
}

export function openCloud(key, { fetch = globalThis.fetch, sleep = wait, timeout = 120_000 } = {}) {
	async function request(resource, { method = "GET", body, contentType, signal = AbortSignal.timeout(15_000) } = {}) {
		const headers = { "x-api-key": key, accept: "application/json" };
		if (contentType) headers["content-type"] = contentType;
		try {
			const response = await fetch(ORIGIN + resource, { method, headers, body, signal, redirect: "error" });
			return { status: response.status, ok: response.ok, data: await response.json().catch(() => undefined) };
		} catch {
			return { ok: false };
		}
	}

	async function read(resource) {
		const result = await request(resource);
		if (!result.ok || !result.data || typeof result.data !== "object") {
			throw new KrfToolError("roblox-read-unverified", `Roblox could not verify ${resource} (HTTP ${result.status ?? "unavailable"}).`);
		}
		return result.data;
	}

	async function verifyTarget(target, startPlace = false) {
		const universe = `universes/${target.universeId}`;
		const place = `${universe}/places/${target.placeId}`;
		const [universeResult, placeResult] = await Promise.all([read(`/cloud/v2/${universe}`), read(`/cloud/v2/${place}`)]);
		if (universeResult.path !== universe || placeResult.path !== place || (startPlace && universeResult.rootPlace !== place) || universeResult.user ||
			(universeResult.group && universeResult.group !== `groups/${target.owner.id}`)) {
			throw new KrfToolError("roblox-target-mismatch", "Roblox did not confirm the expected group owner and place-to-universe association.");
		}
		return universeResult.group ? "verified-by-roblox" : "owner-unreported";
	}

	async function verifyPlaceKey(target) {
		const result = await request("/api-keys/v1/introspect", {
			method: "POST",
			contentType: "application/json",
			body: JSON.stringify({ apiKey: key }),
		});
		const credential = result.data;
		if (!result.ok || credential?.enabled !== true || credential.expired !== false || !Array.isArray(credential.scopes)) {
			throw new KrfToolError("scope-unverified", "Roblox could not confirm the key is active or list its scopes. Verify the key and any IP restrictions in Creator Dashboard.");
		}
		const includes = (ids, id) => Array.isArray(ids) && ids.some((entry) => entry === "*" || String(entry) === id);
		const operations = new Set(credential.scopes
			.filter((scope) => scope.name === "asset" && (includes(scope.groupIds, target.owner.id) || includes(scope.universeIds, target.universeId)))
			.flatMap((scope) => scope.operations ?? []));
		if (!operations.has("read") || !operations.has("write")) {
			throw new KrfToolError("place-write-scope-unverified", `Roblox did not report Assets read and write access for group ${target.owner.id}. Add the assets API system with Read and Write to the key.`);
		}
	}

	async function operate(resource, method, body, verify, onProgress = () => {}) {
		const submitted = await request(resource, { method, body, signal: AbortSignal.timeout(timeout) });
		const operation = submitted.data?.path;
		const unknown = { status: "unknown", hint: "Reconcile this request in Roblox before trying it again." };
		if (!submitted.ok) {
			return REJECTED.has(submitted.status)
				? { status: "failed", httpStatus: submitted.status, robloxError: robloxError(submitted.data) }
				: { ...unknown, httpStatus: submitted.status };
		}
		if (typeof operation !== "string" || !OPERATION.test(operation)) return unknown;
		const operationId = operation.slice("operations/".length);
		onProgress({ status: "submitted", operationId });
		const deadline = AbortSignal.timeout(timeout);
		while (!deadline.aborted) {
			const response = await request(`/assets/v1/${operation}`, { signal: AbortSignal.any([deadline, AbortSignal.timeout(15_000)]) });
			const result = response.data;
			if (response.ok && result?.path === operation && result.done === true) {
				if (result.error && result.error.code !== 0 && result.response === undefined) {
					return { status: "failed", operationId, robloxError: robloxError(result.error) };
				}
				const verified = result.error === undefined ? verify(result.response) : undefined;
				return verified === undefined ? { ...unknown, operationId } : { ...verified, operationId };
			}
			if (response.status !== 429 && REJECTED.has(response.status)) break;
			await sleep(1500, undefined, { signal: deadline }).catch(() => {});
		}
		return { ...unknown, operationId };
	}

	async function publish(target, artifact, onProgress) {
		if (artifact.bytes.length > MAX_PLACE_BYTES) return { status: "failed", publisher: PLACE_PUBLISHER, code: "unsupported-place-artifact", hint: "Roblox accepts place uploads up to 20 MB." };
		const body = multipart({ assetId: Number(target.placeId), assetType: "Place", published: true }, artifact.bytes, "application/octet-stream", "place.rbxl");
		const outcome = await operate(`/assets/v1/assets/${target.placeId}`, "PATCH", body, (asset) => {
			if (asset?.path !== `assets/${target.placeId}` || !isId(asset.revisionId) || asset.isPublished !== true) return undefined;
			return { status: "confirmed-published", revisionId: asset.revisionId };
		}, onProgress);
		return { publisher: PLACE_PUBLISHER, ...outcome };
	}

	return { read, request, verifyTarget, verifyPlaceKey, operate, publish };
}
