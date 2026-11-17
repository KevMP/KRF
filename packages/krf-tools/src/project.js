import { z } from "zod";

export const projectOptionsSchema = z.strictObject({
	mode: z.enum(["full", "hybrid"]),
	ci: z.boolean(),
});

export const PROJECT_OPTION_DEFAULTS = Object.freeze({
	mode: "full",
	ci: true,
});
