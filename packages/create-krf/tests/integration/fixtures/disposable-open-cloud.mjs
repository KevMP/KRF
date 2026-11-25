import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs";

// Preloaded only by the packed-project test. Never forward a request to Roblox.
globalThis.fetch = async (url, { method, body, headers }) => {
	assert.equal(new URL(url).origin, "https://apis.roblox.com");
	assert.equal(headers["x-api-key"], "dev-fixture");
	const resource = new URL(url).pathname;
	if (resource === "/api-keys/v1/introspect") {
		assert.equal(method, "POST");
		assert.equal(JSON.parse(body).apiKey, "dev-fixture");
		return Response.json({ enabled: true, expired: false, scopes: [{ name: "asset", operations: ["read", "write"], groupIds: ["1101"] }] });
	}
	if (method === "PATCH") {
		const match = /^\/assets\/v1\/assets\/(3101|3104)$/.exec(resource);
		assert.ok(match);
		assert.deepEqual(JSON.parse(body.get("request")), { assetId: Number(match[1]), assetType: "Place", published: true });
		const bytes = Buffer.from(await body.get("fileContent").arrayBuffer());
		const config = JSON.parse(fs.readFileSync("package.json", "utf8")).krf;
		if (config.startPlace) {
			const name = match[1] === "3101" ? "lobby" : "dungeon";
			assert.deepEqual(bytes, fs.readFileSync(`build/places/${name}.rbxl`));
			fs.appendFileSync("build/multi-place-uploads.log", `${match[1]}
`);
		} else {
			assert.deepEqual(bytes, fs.readFileSync("full-no-ci.rbxl"));
			fs.writeFileSync("build/upload.sha", createHash("sha256").update(bytes).digest("hex"), { flag: "wx" });
		}
		return Response.json({ path: `operations/place-${match[1]}` });
	}
	assert.equal(method, "GET");
	const operation = /^\/assets\/v1\/operations\/place-(3101|3104)$/.exec(resource);
	if (operation) return Response.json({ path: `operations/place-${operation[1]}`, done: true, response: { path: `assets/${operation[1]}`, revisionId: "53", isPublished: true } });
	if (resource === "/cloud/v2/universes/2101") return Response.json({ path: "universes/2101", group: "groups/1101", rootPlace: "universes/2101/places/3101" });
	if (resource === "/cloud/v2/universes/2101/places/3101") return Response.json({ path: "universes/2101/places/3101" });
	if (resource === "/cloud/v2/universes/2101/places/3104") return Response.json({ path: "universes/2101/places/3104" });
	return Response.json({}, { status: 403 });
};
