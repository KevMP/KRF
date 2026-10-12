--!strict
local types = {}

export type PrimitiveKind = "Boolean" | "U8" | "U16" | "U32" | "I8" | "I16" | "I32" | "F32" | "F64"

export type SchemaDefinition =
	{ kind: PrimitiveKind }
	| { kind: "String", maxBytes: number }
	| { kind: "Enum", values: { string } }
	| { kind: "Optional", inner: SchemaDefinition }
	| { kind: "Struct", fields: { [string]: SchemaDefinition } }
	| { kind: "Array", element: SchemaDefinition, maxLength: number }
	| { kind: "Map", key: SchemaDefinition, value: SchemaDefinition, maxEntries: number }

-- Framework-private metadata for validation, structural diffing, and N2 codecs.
-- Bounds must conservatively cover encoding; N2 owns the exact wire layout.
export type CompiledField = { name: string, schema: CompiledSchema }
export type CompiledSchema =
	{ kind: PrimitiveKind, maxEncodedBytes: number }
	| { kind: "String", maxBytes: number, maxEncodedBytes: number }
	| { kind: "Enum", values: { string }, maxEncodedBytes: number }
	| { kind: "Optional", inner: CompiledSchema, maxEncodedBytes: number }
	| { kind: "Struct", fields: { CompiledField }, maxEncodedBytes: number }
	| { kind: "Array", element: CompiledSchema, maxLength: number, maxEncodedBytes: number }
	| { kind: "Map", key: CompiledSchema, value: CompiledSchema, maxEntries: number, maxEncodedBytes: number }

export type Schema = {
	Boolean: SchemaDefinition,
	U8: SchemaDefinition,
	U16: SchemaDefinition,
	U32: SchemaDefinition,
	I8: SchemaDefinition,
	I16: SchemaDefinition,
	I32: SchemaDefinition,
	F32: SchemaDefinition,
	F64: SchemaDefinition,
	String: (maxBytes: number) -> SchemaDefinition,
	Enum: (values: { string }) -> SchemaDefinition,
	Optional: (inner: SchemaDefinition) -> SchemaDefinition,
	Struct: (fields: { [string]: SchemaDefinition }) -> SchemaDefinition,
	Array: (element: SchemaDefinition, maxLength: number) -> SchemaDefinition,
	Map: (key: SchemaDefinition, value: SchemaDefinition, maxEntries: number) -> SchemaDefinition,
}

export type SchemaCompiler = {
	Compile: (definition: SchemaDefinition) -> (CompiledSchema?, string?),
}

export type SchemaValidator = {
	-- Erased value boundary; accepted values are constrained by the compiled schema.
	Validate: (schema: CompiledSchema, value: any) -> (boolean, string?),
}

return types
