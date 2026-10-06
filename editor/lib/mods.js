'use strict';
// The mods on disk: which folders are mods, their files, and which mod a file belongs to
const fs = require('node:fs');
const path = require('node:path');
const { mask } = require('./luatext');
const { dependenciesIn } = require('./luarc');

// The game takes any folder name made of these, as long as it holds an init.lua or a mod.lua.
const FOLDER = /^[A-Za-z0-9_-]+$/;

// Every .lua file below dir, as "sub/name.lua", sorted.
function listLuaFiles(dir, prefix = '') {
  const out = [];
  let entries = [];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const entry of entries) {
    if (entry.name.startsWith('.')) continue;
    const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isDirectory()) out.push(...listLuaFiles(path.join(dir, entry.name), relative));
    else if (entry.name.endsWith('.lua')) out.push(relative);
  }
  return out.sort();
}

function field(manifest, name) {
  const match = manifest.match(new RegExp(`\\b${name}\\s*=\\s*(["'])((?:\\\\.|(?!\\1).)*)\\1`));
  return match ? match[2].replace(/\\(.)/g, '$1') : null;
}

// What a manifest's text says, read without running it.
function readManifest(text) {
  const clean = mask(text);
  return {
    name: field(clean, 'name'), description: field(clean, 'description'), version: field(clean, 'version'), main: field(clean, 'main'),
    dependencies: dependenciesIn(text),
  };
}

function describeMod(id, dir) {
  const files = listLuaFiles(dir);
  if (!files.includes('init.lua') && !files.includes('mod.lua')) return null;
  let manifest = { name: null, description: null, version: null, main: null, dependencies: [] };
  try {
    manifest = readManifest(fs.readFileSync(path.join(dir, 'mod.lua'), 'utf8'));
  } catch {}
  return {
    id, dir, files,
    name: manifest.name || id,
    description: manifest.description,
    version: manifest.version,
    main: manifest.main || 'init.lua',
    dependencies: manifest.dependencies,
  };
}

// The mods in a folder, sorted by id: { id, dir, files, name, description, version, main, dependencies }.
function scanMods(modsDir) {
  const mods = [];
  if (!modsDir) return mods;
  let entries = [];
  try {
    entries = fs.readdirSync(modsDir, { withFileTypes: true });
  } catch {
    return mods;
  }
  for (const entry of entries) {
    if (!FOLDER.test(entry.name) || entry.name.startsWith('__')) continue;
    const dir = path.join(modsDir, entry.name);
    let isFolder = entry.isDirectory();
    if (!isFolder && entry.isSymbolicLink()) {
      try { isFolder = fs.statSync(dir).isDirectory(); } catch {}
    }
    if (!isFolder) continue;
    const mod = describeMod(entry.name, dir);
    if (mod) mods.push(mod);
  }
  return mods.sort((a, b) => a.id.localeCompare(b.id));
}

// Which of `mods` holds this file: { mod, relative: "sub/name.lua" }, or null.
function modOf(file, mods) {
  const target = path.resolve(file);
  for (const mod of mods) {
    const rest = path.relative(path.resolve(mod.dir), target);
    if (rest && !rest.startsWith('..') && !path.isAbsolute(rest)) return { mod, relative: rest.split(path.sep).join('/') };
  }
  return null;
}

module.exports = { listLuaFiles, readManifest, describeMod, scanMods, modOf };
