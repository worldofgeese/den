#!/usr/bin/env node

import { constants as fsConstants } from 'node:fs';
import { access, copyFile, cp, mkdir, mkdtemp, readFile, realpath, stat, writeFile } from 'node:fs/promises';
import { homedir, constants as osConstants } from 'node:os';
import { delimiter, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { Transform } from 'node:stream';
import { StringDecoder } from 'node:string_decoder';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { stripVTControlCharacters } from 'node:util';

async function findExecutable(name) {
  for (const directory of (process.env.PATH ?? '').split(delimiter)) {
    const candidate = resolve(directory || '.', name);
    try {
      await access(candidate, fsConstants.X_OK);
      if ((await stat(candidate)).isFile()) return candidate;
    } catch (error) {
      if (!['ENOENT', 'ENOTDIR', 'EACCES'].includes(error.code)) throw error;
    }
  }
  return null;
}

function run(command, args) {
  const result = spawnSync(command, args, { stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.signal) {
    console.error(`Agent skills updater stopped by ${result.signal}.`);
    return 128 + (osConstants.signals[result.signal] ?? 0);
  }
  return result.status ?? 1;
}

async function updateSkills(executable, unchecked) {
  if (unchecked.length) {
    console.error(`Agent skills cannot be checked automatically: ${unchecked.map((name) => JSON.stringify(name)).join(', ')}`);
  }
  const child = spawn(executable, ['update', '--global', '--yes'], {
    stdio: ['inherit', 'pipe', 'pipe'],
  });
  let reportedFailure = unchecked.length > 0;
  const deferredSuccess = [];
  function relay(input, output) {
    let pending = '';
    const decoder = new StringDecoder('utf8');
    let scanner;
    function forward(line) {
      const plain = stripVTControlCharacters(line).trim();
      if (plain.startsWith('\u2717 ') || plain.startsWith('Warning:') ||
          /^\d+ skill\(s\) cannot be checked automatically:$/.test(plain)) {
        reportedFailure = true;
      }
      if (plain === '\u2713 All global skills are up to date') {
        deferredSuccess.push({ output, line });
      } else {
        scanner.push(line);
      }
    }
    scanner = new Transform({
      transform(chunk, encoding, callback) {
        pending += decoder.write(chunk);
        let boundary;
        while ((boundary = pending.search(/[\r\n]/)) !== -1) {
          forward(pending.slice(0, boundary + 1));
          pending = pending.slice(boundary + 1);
        }
        callback();
      },
      flush(callback) {
        pending += decoder.end();
        if (pending) forward(pending);
        callback();
      },
    });
    input.pipe(scanner).pipe(output, { end: false });
    return new Promise((resolve, reject) => {
      input.once('error', reject);
      scanner.once('error', reject);
      scanner.once('end', resolve);
    });
  }
  const completion = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', (code, signal) => resolve({ code, signal }));
  });
  const [result] = await Promise.all([
    completion, relay(child.stdout, process.stdout), relay(child.stderr, process.stderr),
  ]);
  if (result.signal) {
    console.error(`Agent skills updater stopped by ${result.signal}.`);
    return 128 + (osConstants.signals[result.signal] ?? 0);
  }
  if (result.code !== 0) return result.code ?? 1;
  if (reportedFailure) {
    console.error('Agent skills update has reported failure, warning, or unchecked skills despite a successful updater exit.');
    return 1;
  }
  for (const { output, line } of deferredSuccess) output.write(line);
  return 0;
}

function contains(parent, child) {
  const path = relative(parent, child);
  return path === '' || (!path.startsWith(`..${sep}`) && path !== '..' && !isAbsolute(path));
}

async function existingDirectory(path) {
  try {
    const resolved = await realpath(path);
    if (!(await stat(resolved)).isDirectory()) {
      throw new Error(`Skill root is not a directory: ${path}`);
    }
    return resolved;
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

async function uncheckedSkills(path) {
  const contents = await readFile(path, 'utf8');
  let lock;
  try {
    lock = JSON.parse(contents);
  } catch (error) {
    if (error instanceof SyntaxError) throw new Error('Global skills lock is not valid JSON.');
    throw error;
  }
  if (!lock || !Number.isInteger(lock.version) || lock.version < 3 ||
      !lock.skills || typeof lock.skills !== 'object' || Array.isArray(lock.skills)) {
    throw new Error('Global skills lock has an invalid or obsolete format.');
  }
  const unchecked = [];
  for (const [name, entry] of Object.entries(lock.skills)) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) {
      throw new Error(`Invalid global skill lock entry: ${JSON.stringify(name)}`);
    }
    if (entry.sourceType === 'well-known' && entry.sourceBaseUrl && entry.wellKnownDigest) continue;
    if (entry.sourceType === 'download' && entry.sourceUrl) continue;
    if (!entry.skillFolderHash || !entry.skillPath) unchecked.push(name);
  }
  return unchecked;
}

async function backupSkills(executable) {
  const packageDir = dirname(dirname(await realpath(executable)));
  const packageInfo = JSON.parse(await readFile(join(packageDir, 'package.json'), 'utf8'));
  const entry = packageInfo.exports?.['.'];
  const libraryPath = typeof entry === 'string' ? entry : entry?.default;
  if (packageInfo.name !== 'skills' || typeof libraryPath !== 'string') {
    throw new Error('The skills executable does not expose a supported agent inventory.');
  }
  const library = await import(pathToFileURL(resolve(packageDir, libraryPath)).href);
  if (typeof library.getSupportedAgents !== 'function') {
    throw new Error('The skills package does not expose a supported agent inventory.');
  }
  const agents = library.getSupportedAgents();
  if (!Array.isArray(agents) || agents.length === 0) {
    throw new Error('The skills package returned an invalid agent inventory.');
  }

  const roots = new Set([join(homedir(), '.agents', 'skills')]);
  for (const agent of agents) {
    if (!agent || (agent.globalSkillsDir !== null &&
        (typeof agent.globalSkillsDir !== 'string' || !isAbsolute(agent.globalSkillsDir)))) {
      throw new Error('The skills package returned an invalid global skill directory.');
    }
    if (agent.globalSkillsDir) roots.add(agent.globalSkillsDir);
  }

  const sources = new Set();
  for (const root of roots) {
    const path = await existingDirectory(root);
    if (path) sources.add(path);
  }

  const stateHome = process.env.XDG_STATE_HOME || join(homedir(), '.local', 'state');
  if (!isAbsolute(stateHome)) throw new Error('XDG_STATE_HOME must be an absolute path.');
  const backupBase = join(stateHome, 'den', 'skill-backups');
  await mkdir(backupBase, { recursive: true, mode: 0o700 });
  const backup = await realpath(await mkdtemp(join(backupBase, 'skills-')));
  for (const source of sources) {
    if (contains(source, backup)) throw new Error(`Backup path overlaps skill root: ${source}`);
  }

  const manifest = { roots: [], lock: null };
  for (const source of sources) {
    const snapshot = join('roots', String(manifest.roots.length));
    await cp(source, join(backup, snapshot), {
      recursive: true,
      dereference: false,
      preserveTimestamps: true,
      verbatimSymlinks: true,
      errorOnExist: true,
      force: false,
    });
    manifest.roots.push({ source, snapshot });
  }

  const lockPath = process.env.XDG_STATE_HOME
    ? join(process.env.XDG_STATE_HOME, 'skills', '.skill-lock.json')
    : join(homedir(), '.agents', '.skill-lock.json');
  try {
    await copyFile(lockPath, join(backup, 'skill-lock.json'), fsConstants.COPYFILE_EXCL);
    manifest.lock = { path: lockPath, snapshot: 'skill-lock.json' };
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  await writeFile(join(backup, 'manifest.json'), JSON.stringify(manifest, null, 2), { mode: 0o600 });
  console.log(`Skill backups: ${backup}`);
  return manifest.lock ? uncheckedSkills(join(backup, manifest.lock.snapshot)) : [];
}

async function main() {
  const executable = await findExecutable('skills');
  if (!executable) {
    if (process.argv[2] === '--npx') throw new Error('The package runner did not provide skills.');
    const npx = await findExecutable('npx');
    if (!npx) throw new Error('Neither skills nor npx is available.');
    process.exitCode = run(npx, [
      '--yes', '--package=skills', '--', process.execPath, fileURLToPath(import.meta.url), '--npx',
    ]);
    return;
  }
  const unchecked = await backupSkills(executable);
  process.exitCode = await updateSkills(executable, unchecked);
}

main().catch((error) => {
  console.error(`Agent skills update failed: ${error.message}`);
  process.exitCode = 1;
});
