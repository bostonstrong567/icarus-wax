// Shared by the test files: paths, scratch folders inside the workspace's build folder, and the pure modules
import fs from 'node:fs';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

export const require = createRequire(import.meta.url);
export const EXTENSION = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const ROOT = path.resolve(EXTENSION, '..', '..');
export const LUA = path.join(ROOT, 'tools', 'lua', 'lua54', 'lua.exe');
export const LANGUAGE_SERVER = path.join(ROOT, 'tools', 'lua', 'lua-language-server', 'bin', 'lua-language-server.exe');

const SCRATCH = path.join(ROOT, 'build', '.wax-vscode-test');

// A new empty folder that is removed when the test (or suite) `t` ends.
export function scratch(t) {
  const dir = path.join(SCRATCH, randomBytes(6).toString('hex'));
  fs.mkdirSync(dir, { recursive: true });
  t.after(() => {
    fs.rmSync(dir, { recursive: true, force: true });
    try { fs.rmdirSync(SCRATCH); } catch {}
  });
  return dir;
}

// Writes files given as { "relative/path": "text" } under dir.
export function put(dir, files) {
  for (const [name, text] of Object.entries(files)) {
    const file = path.join(dir, name);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, text);
  }
}

export const read = (file) => fs.readFileSync(file, 'utf8');

// A folder laid out like the Wax runtime the game loads.
export function makeRuntime(dir) {
  put(dir, { 'Scripts/main.lua': '-- stage 0\n' });
  fs.mkdirSync(path.join(dir, 'mods'), { recursive: true });
  return dir;
}

// A folder laid out like the game as Steam installs it, without Wax in it.
export function makeGame(dir) {
  put(dir, { 'Icarus/Binaries/Win64/Icarus-Win64-Shipping.exe': '' });
  return dir;
}

// Where Wax goes in a game folder.
export const waxIn = (game) => path.join(game, 'Icarus', 'Binaries', 'Win64', 'ue4ss', 'Mods', 'Wax');

// Lists the mods under modsDir in <dir>/run/mods.index.lua, the way the command-line tool tells the game about them.
export function writeIndex(dir, modsDir) {
  const { scanMods } = require('../lib/mods.js');
  const lines = scanMods(modsDir).map((mod) =>
    `  { id = "${mod.id}", dir = "${mod.dir.replaceAll('\\', '/')}", files = { ${mod.files.map((file) => `"${file}"`).join(', ')} } },`);
  put(dir, { 'run/mods.index.lua': `return { mods = {\n${lines.join('\n')}\n} }\n` });
}

// Starts fake_game.lua with `dir` as the game's Wax folder (a folder below one named Binaries, as waxIn gives) and keeps its frames going until the test ends.
// dev: whether dev.txt is in that folder, as in a mod author's install. Without it the game answers commands and runs no Lua.
export async function startStandInGame(t, dir, { dev = true } = {}) {
  for (const folder of ['run/in', 'run/out', 'saved', 'Scripts', 'mods']) fs.mkdirSync(path.join(dir, folder), { recursive: true });
  if (dev) fs.writeFileSync(path.join(dir, 'dev.txt'), '');
  const child = spawn(LUA, [path.join('wax', 'vscode', 'test', 'fake_game.lua'), dir], { cwd: ROOT, stdio: ['pipe', 'pipe', 'pipe'] });
  const game = { stderr: '' };
  child.stderr.on('data', (data) => { game.stderr += data; });
  child.stdin.on('error', () => {});
  const frames = setInterval(() => child.stdin.write('\n'.repeat(8)), 2);
  t.after(async () => {
    clearInterval(frames);
    if (child.exitCode === null) {
      child.stdin.write('quit\n');
      await once(child, 'exit');
    }
  });
  await new Promise((resolve, reject) => {
    child.stdout.once('data', resolve);
    child.once('exit', () => reject(new Error(`the stand-in game stopped:\n${game.stderr}`)));
  });
  child.stdout.resume();
  return game;
}
