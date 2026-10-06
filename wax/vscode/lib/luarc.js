'use strict';
// The .luarc.json that makes the Lua language server understand one mod folder. wax/cli/editor.mjs uses this too.
const fs = require('node:fs');
const path = require('node:path');
const { mask } = require('./luatext');

const slashes = (file) => file.split(path.sep).join('/');
const relative = (from, to) => slashes(path.relative(from, to));

// The ids listed under dependencies in a manifest's text.
function dependenciesIn(manifest) {
  const list = mask(manifest).match(/dependencies\s*=\s*\{([^}]*)\}/);
  return list ? [...list[1].matchAll(/["']([\w-]+)["']/g)].map((m) => m[1]) : [];
}

function dependenciesOf(dir) {
  try {
    return dependenciesIn(fs.readFileSync(path.join(dir, 'mod.lua'), 'utf8'));
  } catch {
    return [];
  }
}

// Settings for the folder `dir`. mods: id -> folder of the mods it may depend on. absolute: write full paths.
function settingsFor({ dir, types, plugin, mods = new Map(), absolute = false }) {
  const refer = absolute ? (to) => slashes(path.resolve(to)) : (to) => relative(dir, to);
  const library = [refer(types)];
  for (const dependency of dependenciesOf(dir)) {
    if (mods.has(dependency)) library.push(relative(dir, mods.get(dependency)));
  }
  return {
    'runtime.version': 'Lua 5.4',
    'runtime.builtin': { basic: 'disable' },
    'runtime.plugin': refer(plugin),
    'workspace.library': library,
    'workspace.checkThirdParty': 'Disable',
    'diagnostics.disable': ['lowercase-global'],
  };
}

const textFor = (settings) => JSON.stringify(settings, null, 4) + '\n';

const NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;
// mod.id and the like are facts about the mod, so a file with one of these names is only reached by its name.
const TAKEN = new Set(['id', 'name', 'version', 'dir']);

// The definitions that make mod.<file> and mod.<folder>.<file> complete. files: the mod's Lua files, as "extras/Utils.lua".
function filesText(id, files) {
  const root = { folders: new Map(), files: [], init: false };
  for (const file of [...files].sort()) {
    const parts = file.replace(/\.lua$/i, '').split('/');
    if (parts.some((part) => !NAME.test(part))) continue;
    let node = root;
    for (const folder of parts.slice(0, -1)) {
      if (!node.folders.has(folder)) node.folders.set(folder, { folders: new Map(), files: [], init: false });
      node = node.folders.get(folder);
    }
    const last = parts[parts.length - 1];
    if (last === 'init') node.init = true;
    else if (!(node === root && last === 'mod')) node.files.push(last);
  }
  const blocks = [];
  const describe = (node, name, trail) => {
    const lines = [`---@class ${name}${trail.length && node.init ? ': WaxFile' : ''}`];
    const here = trail.length ? trail.join('/') + '/' : '';
    for (const file of node.files) {
      if (!trail.length && TAKEN.has(file)) continue;
      if (node.folders.has(file)) continue;
      lines.push(`---@field ${file} WaxFile ${here}${file}.lua`);
    }
    for (const [folder, inner] of node.folders) {
      if (!trail.length && TAKEN.has(folder)) continue;
      const className = `WaxFolder.${id}.${[...trail, folder].join('.')}`;
      lines.push(`---@field ${folder} ${className} The folder ${here}${folder}`);
      describe(inner, className, [...trail, folder]);
    }
    blocks.unshift(lines.join('\n'));
  };
  describe(root, 'WaxModInfo', []);
  return '---@meta\n-- Wax writes this file so the editor knows the files of this mod. It is written again when they change.\n\n'
    + blocks.join('\n\n') + '\n';
}

// Writes <dir>/.wax/files.lua unless it already says the same. Returns true when the file changed.
function writeFiles(dir, files) {
  const file = path.join(dir, '.wax', 'files.lua');
  const text = filesText(path.basename(dir), files);
  try {
    if (fs.readFileSync(file, 'utf8') === text) return false;
  } catch {}
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text);
  return true;
}

// Writes <dir>/.luarc.json unless it already says the same. Returns true when the file changed.
function write(dir, settings) {
  const file = path.join(dir, '.luarc.json');
  const text = textFor(settings);
  try {
    if (fs.readFileSync(file, 'utf8') === text) return false;
  } catch {}
  fs.writeFileSync(file, text);
  return true;
}

module.exports = { dependenciesIn, dependenciesOf, settingsFor, textFor, write, filesText, writeFiles };
