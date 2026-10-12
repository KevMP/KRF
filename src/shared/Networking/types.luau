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
export type CompiledField = { read name: string, read schema: CompiledSchema }
export type CompiledSchema =
	{ kind: PrimitiveKind, maxEncodedBytes: number }
	| { kind: "String", maxBytes: number, maxEncodedBytes: number }
	| { kind: "Enum", values: { string }, ordinalsByValue: { [string]: number }, maxEncodedBytes: number }
	| { kind: "Optional", inner: CompiledSchema, maxEncodedBytes: number }
	| { kind: "Struct", fields: { CompiledField }, fieldsByName: { [string]: CompiledSchema }, maxEncodedBytes: number }
	| { kind: "Array", element: CompiledSchema, maxLength: number, maxEncodedBytes: number }
	| { kind: "Map", key: CompiledSchema, value: CompiledSchema, maxEntries: number, maxEncodedBytes: number }

export type Schema = {
	read Boolean: SchemaDefinition,
	read U8: SchemaDefinition,
	read U16: SchemaDefinition,
	read U32: SchemaDefinition,
	read I8: SchemaDefinition,
	read I16: SchemaDefinition,
	read I32: SchemaDefinition,
	read F32: SchemaDefinition,
	read F64: SchemaDefinition,
	read String: (maxBytes: number) -> SchemaDefinition,
	read Enum: (values: { string }) -> SchemaDefinition,
	read Optional: (inner: SchemaDefinition) -> SchemaDefinition,
	read Struct: (fields: { [string]: SchemaDefinition }) -> SchemaDefinition,
	read Array: (element: SchemaDefinition, maxLength: number) -> SchemaDefinition,
	read Map: (key: SchemaDefinition, value: SchemaDefinition, maxEntries: number) -> SchemaDefinition,
}

export type SchemaCompiler = {
	Compile: (definition: SchemaDefinition) -> (CompiledSchema?, string?),
}

export type SchemaValidator = {
	-- Erased value boundary; accepted values are constrained by the compiled schema.
	Validate: (schema: CompiledSchema, value: any) -> (boolean, string?),
}

return types
