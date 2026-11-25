import { createHash } from "node:crypto";
import { zstdDecompressSync } from "node:zlib";

import { KrfToolError } from "../errors.js";

const MAGIC = Buffer.from("3c726f626c6f782189ff0d0a1a0a0000", "hex");
const MAX_CHUNK = 128 * 1024 * 1024;
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

function lz4(source, size) {
	const output = Buffer.alloc(size);
	let input = 0;
	let written = 0;
	function length(initial) {
		let total = initial;
		if (initial === 15) {
			let next;
			do {
				if (input === source.length) throw new Error("truncated LZ4 length");
				next = source[input++];
				total += next;
			} while (next === 255);
		}
		return total;
	}
	while (input < source.length) {
		const token = source[input++];
		const literal = length(token >> 4);
		if (input + literal > source.length || written + literal > size) throw new Error("invalid LZ4 literals");
		source.copy(output, written, input, input + literal);
		input += literal;
		written += literal;
		if (input === source.length) break;
		const distance = source.readUInt16LE(input);
		input += 2;
		const match = length(token & 15) + 4;
		if (distance === 0 || distance > written || written + match > size) throw new Error("invalid LZ4 match");
		for (let end = written + match; written < end; written++) output[written] = output[written - distance];
	}
	if (written !== size) throw new Error("incomplete LZ4 block");
	return output;
}

function decode(chunk, compressed, size) {
	if (!compressed) return chunk;
	const data = chunk.subarray(0, 4).toString("hex") === "28b52ffd"
		? zstdDecompressSync(chunk, { maxOutputLength: size })
		: lz4(chunk, size);
	if (data.length !== size) throw new Error("incorrect chunk length");
	return data;
}

export function inspectPlace(bytes) {
	try {
		if (bytes.length < 48 || !bytes.subarray(0, MAGIC.length).equals(MAGIC)) throw new Error("invalid header");
		const classes = new Set();
		let instances = 0;
		let parents = false;
		for (let offset = 32; offset + 16 <= bytes.length;) {
			const tag = bytes.toString("ascii", offset, offset + 4);
			const compressed = bytes.readUInt32LE(offset + 4);
			const size = bytes.readUInt32LE(offset + 8);
			const end = offset + 16 + (compressed || size);
			if (end > bytes.length || size > MAX_CHUNK) throw new Error("invalid chunk size");
			const chunk = bytes.subarray(offset + 16, end);
			offset = end;
			if (tag === "END\0") {
				if (!parents || compressed || chunk.toString() !== "</roblox>" || end !== bytes.length ||
					classes.size !== bytes.readUInt32LE(16) || instances !== bytes.readUInt32LE(20) || !classes.has("Workspace")) break;
				return { bytes, placeSha256: sha256(bytes) };
			}
			const data = decode(chunk, compressed, size);
			if (tag === "INST") {
				const length = data.readUInt32LE(4);
				const name = data.toString("ascii", 8, 8 + length);
				const count = data.readUInt32LE(9 + length);
				if (!/^[A-Za-z][A-Za-z0-9]*$/.test(name) || classes.has(name) || count === 0 || 13 + length + count * 4 > data.length) break;
				classes.add(name);
				instances += count;
			} else if (tag === "PRNT") {
				if (parents || data[0] !== 0 || data.readUInt32LE(1) !== instances || data.length !== 5 + 8 * instances) break;
				parents = true;
			} else if (tag !== "PROP" && tag !== "SSTR" && tag !== "META") break;
		}
	} catch {}
	throw new KrfToolError("unsupported-place-artifact", "Expected a complete Rojo binary .rbxl place. Rebuild the Full project with npm run build.");
}
