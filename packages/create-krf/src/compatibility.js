// Versions a project created by this create-krf release targets. Templates are bundled with the
// creator, so the template version is the creator version.
import packageJson from "../package.json" with { type: "json" };

export const CREATOR_VERSION = packageJson.version;
export const TEMPLATE_VERSION = packageJson.version;

/** The released KRF Wally package these templates are written against. */
export const KRF_RUNTIME = Object.freeze({ package: "kevmp/krf", version: "0.1.0" });

/** The project-local tooling generated projects pin; it is published before this creator. */
export const KRF_TOOLING = Object.freeze({ package: "krf-tools", version: packageJson.dependencies["krf-tools"] });
