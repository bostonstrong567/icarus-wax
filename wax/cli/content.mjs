#!/usr/bin/env node
// A mod's game content: cooks the assets under unreal/Icarus/Content/Mods/<Id>, puts the pak in the mod, tells the game.
//   node wax/cli/content.mjs new <Id>       make the assets folder for a mod
//   node wax/cli/content.mjs build <Id>     cook, pack, copy into the mod, reload the mod in a running game
//   node wax/cli/content.mjs watch [<Id>]   build whenever an asset of the mod (or of any mod) is saved
//   node wax/cli/content.mjs status         what the running game has mounted
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { ROOT, evalLua, gameRunning } from './bridge.mjs';
import { modRoots } from './mods.mjs';

const ASSETS = path.join(ROOT, 'unreal', 'Icarus', 'Content', 'Mods');
const COOK = path.join(ROOT, 'scripts', 'Cook-UnrealProject.ps1');
const ID = /^[A-Za-z][A-Za-z0-9_]*$/;
const ASSET_FILE = /\.(uasset|umap)$/i;
const QUIET_MS = 4000;

function fail(message) {
  console.error(message);
  process.exit(1);
}

function modDir(id) {
  for (const root of modRoots()) {
    const dir = path.join(root, id);
    if (fs.existsSync(path.join(dir, 'init.lua')) || fs.existsSync(path.join(dir, 'mod.lua'))) return dir;
  }
  return null;
}

function checkId(id) {
  if (!id || !ID.test(id)) fail('Give the id of a mod: letters, digits and _, starting with a letter.');
  return id;
}

function run(command, args) {
  return new Promise((resolve) => {
    const child = spawn(command, args, { stdio: 'inherit', cwd: ROOT });
    child.on('error', () => resolve(1));
    child.on('exit', (code) => resolve(code ?? 1));
  });
}

async function tellGame(id) {
  if (!gameRunning()) {
    console.log('The game is not running. It mounts the content the next time the mod loads.');
    return;
  }
  try {
    await evalLua(`Wax.mods.request_reload(${JSON.stringify(id)}) return true`, { timeoutSec: 10 });
    // the game may wait a few frames for an older copy to be let go of
    for (let i = 0; i < 20; i++) {
      await new Promise((resolve) => setTimeout(resolve, 250));
      const answer = await evalLua(`local s = Wax.import("mods.content").state(${JSON.stringify(id)}) return s`, { timeoutSec: 10 });
      const state = answer.values?.[0];
      if (state && !state.waiting && state.state) {
        console.log(state.state === 'ready' ? `The game has it: ${state.files} files, ready.`
          : state.state === 'restart' ? `The game has it. ${state.reason}.` : `The game did not take it: ${state.reason}`);
        return;
      }
    }
    console.log('The game was told. It has not said yet whether the content is mounted.');
  } catch (error) {
    console.log(`The game could not be told (${error.message}). Reload the mod there to mount the content.`);
  }
}

async function build(id) {
  const dir = modDir(id);
  if (!dir) fail(`There is no mod named ${id} in ${modRoots().join(' or ')}.`);
  if (!fs.existsSync(path.join(ASSETS, id))) fail(`${id} has no assets yet. Make the folder with: node wax/cli/content.mjs new ${id}`);
  if (!fs.existsSync(COOK)) fail(`${COOK} is not there. Cooking needs the Wax workspace with the Unreal editor.`);
  const started = Date.now();
  const code = await run('pwsh', ['-NoProfile', '-File', COOK, '-Content', id]);
  if (code !== 0) fail(`Cooking ${id} failed (exit ${code}). The mod keeps the content it had.`);
  const pak = path.join(ROOT, 'build', `${id}.pak`);
  if (!fs.existsSync(pak)) fail(`The cook wrote no ${pak}.`);
  const target = path.join(dir, 'content', `${id}.pak`);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  // written beside and renamed, so the game never reads half a file
  fs.copyFileSync(pak, `${target}.new`);
  fs.renameSync(`${target}.new`, target);
  console.log(`${path.relative(ROOT, target)}: ${fs.statSync(target).size} bytes, in ${((Date.now() - started) / 1000).toFixed(0)} s.`);
  await tellGame(id);
  return true;
}

function watch(only) {
  if (!fs.existsSync(ASSETS)) fail(`${ASSETS} is not there.`);
  const waiting = new Map();
  let busy = false;
  const queue = [];
  const next = async () => {
    if (busy || !queue.length) return;
    busy = true;
    const id = queue.shift();
    console.log(`\n[${new Date().toLocaleTimeString()}] ${id} changed.`);
    try {
      await build(id);
    } catch (error) {
      console.error(error.message);
    }
    busy = false;
    next();
  };
  fs.watch(ASSETS, { recursive: true }, (_event, file) => {
    if (!file || !ASSET_FILE.test(file)) return;
    const id = file.split(/[\\/]/)[0];
    if ((only && id !== only) || !ID.test(id) || !modDir(id)) return;
    clearTimeout(waiting.get(id));
    waiting.set(id, setTimeout(() => {
      waiting.delete(id);
      if (!queue.includes(id)) queue.push(id);
      next();
    }, QUIET_MS));
  });
  console.log(`Watching ${path.relative(ROOT, ASSETS)}${only ? path.sep + only : ''}. Save an asset in the editor and its mod's content is built. Ctrl+C stops.`);
}

const [action, argument] = process.argv.slice(2);
if (action === 'new') {
  const id = checkId(argument);
  if (!modDir(id)) fail(`There is no mod named ${id}. Make the mod first.`);
  fs.mkdirSync(path.join(ASSETS, id), { recursive: true });
  console.log(`Assets of ${id} go in ${path.join(ASSETS, id)} (the game's /Game/Mods/${id}).`);
  console.log('Open the project with scripts\\Open-UnrealProject.ps1, save assets there, then build.');
} else if (action === 'build') {
  // fail() inside build exits; a build that returns is done
  process.exitCode = (await build(checkId(argument))) ? 0 : 1;
} else if (action === 'watch') {
  watch(argument ? checkId(argument) : null);
} else if (action === 'status') {
  if (!gameRunning()) fail('The game is not running.');
  const answer = await evalLua('return Wax.import("mods.content").list()', { timeoutSec: 10 });
  const list = answer.values?.[0] ?? [];
  if (!Array.isArray(list) || !list.length) console.log('No mod with game content is loaded.');
  else for (const entry of list) console.log(`${entry.id}: ${entry.state ?? 'not looked at'}${entry.reason ? ` (${entry.reason})` : ''}, ${entry.files} files`);
} else {
  fail('Usage: node wax/cli/content.mjs new <Id> | build <Id> | watch [<Id>] | status');
}
