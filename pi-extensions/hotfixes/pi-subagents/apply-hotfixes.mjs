#!/usr/bin/env node
/**
 * Re-apply repo-managed patches to the installed pi-subagents npm package.
 * Idempotent: exits 0 when already patched; nonzero on version/snippet drift.
 */
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const TARGET_VERSIONS = ["0.27.0"];
const PATCH_ID = "getFinalOutput-last-text-part";

const OLD_SNIPPET = `			for (const part of msg.content) {
				if (part.type === "text" && part.text.trim().length > 0) return part.text;
			}`;

const NEW_SNIPPET = `			for (let j = msg.content.length - 1; j >= 0; j--) {
				const part = msg.content[j];
				if (part.type === "text" && part.text.trim().length > 0) return part.text;
			}`;

function agentDir() {
	const configured = process.env.PI_CODING_AGENT_DIR;
	if (configured === "~") return os.homedir();
	if (configured?.startsWith("~/")) return path.join(os.homedir(), configured.slice(2));
	return configured || path.join(os.homedir(), ".pi", "agent");
}

function fail(message) {
	console.error(`pi-subagents hotfix (${PATCH_ID}): ${message}`);
	process.exit(1);
}

// pi-subagents may be installed unscoped (pi >=0.27) or scoped under
// @tintinweb (pi <0.10). Try both; skip gracefully if neither is present
// (fresh install before `pi update`, or version without the bug).
const nmDir = path.join(agentDir(), "npm", "node_modules");
const candidates = [
	path.join(nmDir, "pi-subagents"),
	path.join(nmDir, "@tintinweb", "pi-subagents"),
];
const pkgRoot = candidates.find((p) => fs.existsSync(path.join(p, "package.json")));

if (!pkgRoot) {
	console.log(`pi-subagents hotfix (${PATCH_ID}): package not installed yet, skipping`);
	process.exit(0);
}

const pkgJsonPath = path.join(pkgRoot, "package.json");
const utilsPath = path.join(pkgRoot, "src", "shared", "utils.ts");

let pkg;
try {
	pkg = JSON.parse(fs.readFileSync(pkgJsonPath, "utf8"));
} catch (error) {
	fail(`failed to read ${pkgJsonPath}: ${error instanceof Error ? error.message : String(error)}`);
}

if (!TARGET_VERSIONS.includes(pkg.version)) {
	console.log(
		`pi-subagents hotfix (${PATCH_ID}): version ${pkg.version} not in target set [${TARGET_VERSIONS.join(", ")}], skipping`,
	);
	process.exit(0);
}

if (!fs.existsSync(utilsPath)) {
	console.log(`pi-subagents hotfix (${PATCH_ID}): utils.ts not found (pre-compiled dist?), skipping`);
	process.exit(0);
}

const source = fs.readFileSync(utilsPath, "utf8");

if (source.includes(NEW_SNIPPET)) {
	console.log(`pi-subagents hotfix (${PATCH_ID}): already applied`);
	process.exit(0);
}

if (!source.includes(OLD_SNIPPET)) {
	fail(
		`expected upstream snippet missing in ${utilsPath}; manual review required before patching`,
	);
}

const patched = source.replace(OLD_SNIPPET, NEW_SNIPPET);
fs.writeFileSync(utilsPath, patched, "utf8");
console.log(`pi-subagents hotfix (${PATCH_ID}): applied to ${utilsPath}`);
