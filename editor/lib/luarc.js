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

module.exports = { dependenciesIn, dependenciesOf, settingsFor, textFor, write };
