const fs = require("fs");
const path = require("path");

const REPO_ROOT = path.resolve(__dirname, "..");
const DEFAULT_INPUT_FILE = path.join(REPO_ROOT, "coverage", "coverage-final.json");
const DEFAULT_OUTPUT_FILE = path.join(REPO_ROOT, ".nyc_output", "coverage.json");
const ROBLOX_SOURCE_PREFIX = "ReplicatedStorage/Packages/KRF/";
const SOURCE_EXTENSIONS = [".luau", ".lua"];

function resolveRepoPath(filePath) {
	if (!filePath.startsWith(ROBLOX_SOURCE_PREFIX)) {
		return filePath;
	}

	const repoRelativePath = path.posix.join("src", filePath.slice(ROBLOX_SOURCE_PREFIX.length));
	if (path.posix.extname(repoRelativePath) !== "") {
		return repoRelativePath;
	}

	const absoluteBasePath = path.join(REPO_ROOT, ...repoRelativePath.split("/"));
	for (const extension of SOURCE_EXTENSIONS) {
		if (fs.existsSync(absoluteBasePath + extension)) {
			return repoRelativePath + extension;
		}
	}

	return repoRelativePath;
}

function normalizeCoverageReport(report) {
	return Object.fromEntries(
		Object.entries(report).map(([filePath, fileCoverage]) => {
			const normalizedPath = resolveRepoPath(filePath);
			return [
				normalizedPath,
				{
					...fileCoverage,
					path: normalizedPath,
				},
			];
		}),
	);
}

function main() {
	const inputFilePath = path.resolve(process.argv[2] || DEFAULT_INPUT_FILE);
	const outputFilePath = path.resolve(process.argv[3] || DEFAULT_OUTPUT_FILE);

	if (!fs.existsSync(inputFilePath)) {
		throw new Error(`Coverage file not found: ${inputFilePath}`);
	}

	const rawJson = fs.readFileSync(inputFilePath, "utf8").replace(/^\uFEFF/, "");
	const normalizedReport = normalizeCoverageReport(JSON.parse(rawJson));

	fs.mkdirSync(path.dirname(outputFilePath), { recursive: true });
	fs.writeFileSync(outputFilePath, JSON.stringify(normalizedReport), "utf8");

	console.log(`Prepared nyc coverage input: ${outputFilePath}`);
}

main();
