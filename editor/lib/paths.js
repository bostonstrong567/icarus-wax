'use strict';
// Finds the game, the Wax folder inside it (the one the game loads, holding Scripts and mods) and the folder mods live in
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const APP_ID = '1149460';
const EXE_IN_GAME = ['Icarus', 'Binaries', 'Win64', 'Icarus-Win64-Shipping.exe'];
const WAX_IN_GAME = ['Icarus', 'Binaries', 'Win64', 'ue4ss', 'Mods', 'Wax'];
// Where Steam writes its install folder: [key, value name].
const STEAM_KEYS = [
  ['HKCU\\Software\\Valve\\Steam', 'SteamPath'],
  ['HKLM\\SOFTWARE\\WOW6432Node\\Valve\\Steam', 'InstallPath'],
  ['HKLM\\SOFTWARE\\Valve\\Steam', 'InstallPath'],
];

function isFile(file) {
  try { return fs.statSync(file).isFile(); } catch { return false; }
}

function isDir(dir) {
  try { return fs.statSync(dir).isDirectory(); } catch { return false; }
}

const isRuntime = (dir) => isFile(path.join(dir, 'Scripts', 'main.lua'));
const isGame = (dir) => isFile(path.join(dir, ...EXE_IN_GAME));
const waxIn = (game) => path.join(game, ...WAX_IN_GAME);

const key = (file) => path.resolve(file).toLowerCase();
const samePath = (a, b) => key(a) === key(b);

// True when `file` is `dir` or anywhere below it.
function isInside(dir, file) {
  const rest = path.relative(path.resolve(dir), path.resolve(file));
  return rest === '' || (!rest.startsWith('..') && !path.isAbsolute(rest));
}

// The game folder that `dir` is, or is somewhere inside of. Null when it is neither.
function gameAround(dir) {
  let current = path.resolve(dir);
  for (let depth = 0; depth < 10; depth++) {
    if (isGame(current)) return current;
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  return null;
}

// The game folder just below a Steam library, its steamapps folder or steamapps\common. Null when there is none.
function gameBelow(dir) {
  const places = [['Icarus'], ['common', 'Icarus'], ['steamapps', 'common', 'Icarus']];
  return places.map((place) => path.join(dir, ...place)).find(isGame) ?? null;
}

// What a folder someone pointed at holds: { runtime, game }. It may be the game folder, the Wax folder or one near them.
function describeFolder(dir) {
  const chosen = path.resolve(String(dir));
  if (isRuntime(chosen)) return { runtime: chosen, game: gameAround(chosen) };
  const game = gameAround(chosen) ?? gameBelow(chosen);
  if (game) return { runtime: isRuntime(waxIn(game)) ? waxIn(game) : null, game };
  for (let skip = 0; skip < WAX_IN_GAME.length; skip++) {
    const runtime = path.join(chosen, ...WAX_IN_GAME.slice(skip));
    if (isRuntime(runtime)) return { runtime, game: null };
  }
  return { runtime: null, game: null };
}

const unescape = (text) => text.replace(/\\(.)/g, '$1');

// The library folders listed in Steam's libraryfolders.vdf, in the form Steam writes today and the one before it.
function parseLibraryFolders(text) {
  const found = [];
  const source = String(text);
  for (const match of source.matchAll(/"path"\s+"((?:[^"\\]|\\.)*)"/gi)) found.push(unescape(match[1]));
  for (const match of source.matchAll(/"\d+"[ \t]+"((?:[^"\\]|\\.)*)"/g)) {
    // an app's size is a number too, a library is a path
    if (/[\\/]/.test(match[1])) found.push(unescape(match[1]));
  }
  return found;
}

// The game's folder name under steamapps/common, from its appmanifest.
function parseInstallDir(manifest) {
  const match = String(manifest).match(/"installdir"\s+"([^"]*)"/i);
  return match ? match[1] : null;
}

const registry = new Map();

// The folders the registry names for Steam. Each key is asked once: the answer does not change while VS Code is open.
function steamFromRegistry(keys = STEAM_KEYS) {
  if (process.platform !== 'win32') return [];
  for (const [where, name] of keys) {
    if (registry.has(where)) continue;
    registry.set(where, null);
    try {
      const out = execFileSync('reg', ['query', where, '/v', name],
        { encoding: 'utf8', windowsHide: true, timeout: 3000, stdio: ['ignore', 'pipe', 'ignore'] });
      const match = out.match(new RegExp(`${name}\\s+REG_(?:EXPAND_)?SZ\\s+(.+)`));
      if (match) registry.set(where, path.normalize(match[1].trim()));
    } catch {}
  }
  return keys.map(([where]) => registry.get(where)).filter(Boolean);
}

// Where Steam itself may be installed: what the registry says, then the usual folders.
function steamRoots(env = process.env, fromRegistry = steamFromRegistry) {
  const roots = [...[fromRegistry()].flat(), env['ProgramFiles(x86)'] && path.join(env['ProgramFiles(x86)'], 'Steam'),
    env.ProgramFiles && path.join(env.ProgramFiles, 'Steam'), env.ProgramW6432 && path.join(env.ProgramW6432, 'Steam')];
  const seen = new Set();
  return roots.filter((root) => root && !seen.has(key(root)) && seen.add(key(root)));
}

// Every Steam library: each root, and every folder its libraryfolders.vdf lists.
function steamLibraries(roots) {
  const libraries = [];
  const seen = new Set();
  const add = (dir) => {
    if (dir && !seen.has(key(dir))) {
      seen.add(key(dir));
      libraries.push(dir);
    }
  };
  for (const root of roots) {
    add(root);
    for (const folder of ['steamapps', 'config']) {
      try {
        parseLibraryFolders(fs.readFileSync(path.join(root, folder, 'libraryfolders.vdf'), 'utf8')).forEach(add);
      } catch {}
    }
  }
  return libraries;
}

// Every copy of the game in the libraries of these Steam folders: [{ game, runtime }]. runtime is null where Wax is not installed.
function gamesIn(roots) {
  const games = [];
  for (const library of steamLibraries(roots)) {
    let folder = null;
    try {
      folder = parseInstallDir(fs.readFileSync(path.join(library, 'steamapps', `appmanifest_${APP_ID}.acf`), 'utf8'));
    } catch {}
    const game = path.join(library, 'steamapps', 'common', folder || 'Icarus');
    // without Steam's record of the game, only the game's own exe says it is there
    if (!isDir(game) || (!folder && !isGame(game))) continue;
    games.push({ game, runtime: isRuntime(waxIn(game)) ? waxIn(game) : null });
  }
  return games;
}

// Every copy of the game Steam has. Without roots it finds Steam itself: [{ game, runtime }].
function findSteamGames(roots) {
  if (roots) return gamesIn(roots);
  // the user's own registry key and the usual folders nearly always have it; the other keys are asked when they do not
  const quick = gamesIn(steamRoots(process.env, () => steamFromRegistry(STEAM_KEYS.slice(0, 1))));
  return quick.length ? quick : gamesIn(steamRoots());
}

// Looks in the settings, the open folders, then Steam: { dir: the Wax folder or null, source, game: its folder if found, problem: a wrong setting }.
function findRuntime({ runtimePath = '', gamePath = '', folders = [], steam = findSteamGames } = {}) {
  let problem = null;
  let game = null;
  for (const [name, value] of [['wax.runtimePath', runtimePath], ['wax.gamePath', gamePath]]) {
    const wanted = String(value ?? '').trim();
    if (!wanted) continue;
    const there = describeFolder(wanted);
    if (there.runtime) return { dir: there.runtime, source: 'setting', game: there.game, problem };
    if (there.game) game ??= there.game;
    else problem ??= `The setting ${name} is "${wanted}". That is not the ICARUS folder or the Wax folder.`;
  }
  const from = (dir, source) => ({ dir, source, game: gameAround(dir), problem });
  for (const folder of folders) {
    const dir = path.join(folder, 'wax', 'runtime');
    if (isRuntime(dir)) return from(dir, 'workspace');
  }
  for (const folder of folders) {
    if (isRuntime(folder) && isDir(path.join(folder, 'mods'))) return from(folder, 'folder');
  }
  // the Wax folder's mods folder, or one mod inside it, opened on its own
  for (const folder of folders) {
    const parent = path.dirname(folder);
    if (path.basename(folder).toLowerCase() === 'mods' && isRuntime(parent)) return from(parent, 'folder');
    if (path.basename(parent).toLowerCase() === 'mods' && isRuntime(path.dirname(parent))) return from(path.dirname(parent), 'folder');
  }
  const games = steam();
  const installed = games.find((entry) => entry.runtime);
  if (installed) return { dir: installed.runtime, source: 'steam', game: installed.game, problem };
  return { dir: null, source: null, game: game ?? (games.length ? games[0].game : null), problem };
}

// What to say when the Wax folder was not found: { situation, text, gameFound }. situation names what is missing, not how the settings read.
function missing(found) {
  if (found.game) {
    return {
      situation: `no wax in ${key(found.game)}`, gameFound: true,
      text: `Wax is not installed in the game at ${found.game}. Download it, then run "Install Wax.cmd".`,
    };
  }
  const text = found.problem
    ? `${found.problem} The game was not found anywhere else. Choose the folder ICARUS is installed in.`
    : 'Wax: the ICARUS folder was not found. Choose the folder the game is installed in.';
  return { situation: 'no game', gameFound: false, text };
}

// luamods in the workspace when there is one, otherwise the Wax folder's own mods folder.
function findModsDir({ folders = [], runtime = null } = {}) {
  for (const folder of folders) {
    const dir = path.join(folder, 'luamods');
    if (isDir(dir)) return dir;
  }
  return runtime ? path.join(runtime, 'mods') : null;
}

module.exports = {
  APP_ID, isFile, isDir, isRuntime, isGame, isInside, samePath, gameAround, describeFolder,
  parseLibraryFolders, parseInstallDir, steamRoots, steamLibraries, findSteamGames, findRuntime, missing, findModsDir,
};
