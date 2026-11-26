import { z } from "zod";

export const placeName = z.string()
	.regex(/^[a-z][a-z0-9-]{0,63}$/, "Use lowercase letters, numbers and hyphens, starting with a letter")
	.refine((name) => !/^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])$/.test(name), "This name is reserved on Windows");

export const projectOptionsSchema = z.strictObject({
	mode: z.enum(["full", "hybrid"]),
	ci: z.boolean(),
	agents: z.boolean(),
	places: z.array(placeName).min(1).refine((names) => new Set(names).size === names.length, "Place names must be unique").optional(),
}).refine(({ mode, places }) => mode === "full" || places === undefined, { path: ["places"], message: "Named places require Full mode" });

export const PROJECT_OPTION_DEFAULTS = Object.freeze({
	mode: "full",
	ci: true,
	agents: true,
});
