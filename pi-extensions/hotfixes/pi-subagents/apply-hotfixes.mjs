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

const pkgRoot = path.join(agentDir(), "npm", "node_modules", "pi-subagents");
const pkgJsonPath = path.join(pkgRoot, "package.json");
const utilsPath = path.join(pkgRoot, "src", "shared", "utils.ts");

if (!fs.existsSync(pkgJsonPath)) {
	fail(`package not found at ${pkgRoot}`);
}

let pkg;
try {
	pkg = JSON.parse(fs.readFileSync(pkgJsonPath, "utf8"));
} catch (error) {
	fail(`failed to read ${pkgJsonPath}: ${error instanceof Error ? error.message : String(error)}`);
}

if (!TARGET_VERSIONS.includes(pkg.version)) {
	fail(
		`unsupported pi-subagents version ${pkg.version}; expected one of ${TARGET_VERSIONS.join(", ")}`,
	);
}

if (!fs.existsSync(utilsPath)) {
	fail(`utils.ts not found at ${utilsPath}`);
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
