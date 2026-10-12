--!strict
export type PrimitiveContract = {
	maxEncodedBytes: number,
	minimum: number?,
	maximum: number?,
	isInteger: boolean?,
}

local contracts: { [string]: PrimitiveContract } = {
	Boolean = { maxEncodedBytes = 1 },
	U8 = { maxEncodedBytes = 1, minimum = 0, maximum = 255, isInteger = true },
	U16 = { maxEncodedBytes = 2, minimum = 0, maximum = 65535, isInteger = true },
	U32 = { maxEncodedBytes = 4, minimum = 0, maximum = 4294967295, isInteger = true },
	I8 = { maxEncodedBytes = 1, minimum = -128, maximum = 127, isInteger = true },
	I16 = { maxEncodedBytes = 2, minimum = -32768, maximum = 32767, isInteger = true },
	I32 = { maxEncodedBytes = 4, minimum = -2147483648, maximum = 2147483647, isInteger = true },
	F32 = { maxEncodedBytes = 4, minimum = -3.4028234663852886e38, maximum = 3.4028234663852886e38 },
	F64 = { maxEncodedBytes = 8 },
}

for _, contract: PrimitiveContract in contracts do
	table.freeze(contract)
end

return table.freeze(contracts)
