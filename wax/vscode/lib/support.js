'use strict';
// Editor support: gives each mod folder the .luarc.json that points the Lua language server at Wax's definitions
const fs = require('node:fs');
const path = require('node:path');
const luarc = require('./luarc');
const { scanMods } = require('./mods');
const { isDir, isFile, isInside, isRuntime, samePath } = require('./paths');

// Where the type definitions and the require plugin are: the workspace's own when it has them, else the extension's copy.
function locate({ folders = [], extensionDir }) {
  for (const folder of folders) {
    const types = path.join(folder, 'wax', 'types');
    const plugin = path.join(folder, 'wax', 'lsp', 'plugin.lua');
    if (isDir(types) && isFile(plugin)) return { types, plugin, live: true, root: folder };
  }
  if (!extensionDir) return null;
  // next to a source checkout the originals are beside the extension; once installed there is only the packed copy
  const candidates = [
    [path.join(extensionDir, '..', 'types'), path.join(extensionDir, '..', 'lsp', 'plugin.lua')],
    [path.join(extensionDir, 'bundled', 'types'), path.join(extensionDir, 'bundled', 'lsp', 'plugin.lua')],
  ];
  for (const [types, plugin] of candidates) {
    if (isDir(types) && isFile(plugin)) return { types: path.resolve(types), plugin: path.resolve(plugin), live: false, root: null };
  }
  return null;
}

// True for a .luarc.json this extension wrote for a folder of mods (so it may be rewritten when paths change).
function isOurs(file) {
  try {
    const plugin = JSON.parse(fs.readFileSync(file, 'utf8'))['runtime.plugin'];
    return typeof plugin === 'string' && /\/bundled\/lsp\/plugin\.lua$/.test(plugin);
  } catch {
    return false;
  }
}

// The settings for a workspace folder that holds several mods, or null when it should be left alone.
function folderSettings(folder, modsDir, where) {
  const absolute = !(where.live && isInside(where.root, folder));
  if (samePath(folder, modsDir)) return luarc.settingsFor({ dir: folder, types: where.types, plugin: where.plugin, absolute });
  if (isRuntime(folder) && samePath(path.join(folder, 'mods'), modsDir)) {
    const settings = luarc.settingsFor({ dir: folder, types: where.types, plugin: where.plugin, absolute });
    // only the mods are the user's code; the rest of the folder is Wax itself
    settings['workspace.ignoreDir'] = fs.readdirSync(folder, { withFileTypes: true })
      .filter((entry) => entry.isDirectory() && entry.name.toLowerCase() !== 'mods')
      .map((entry) => entry.name).sort();
    return settings;
  }
  return null;
}

// Writes a .luarc.json into every mod folder, and into an open folder of mods that has none. Returns { mods, changed, where } or { problem }.
function setUp({ folders = [], modsDir, extensionDir }) {
  const where = locate({ folders, extensionDir });
  if (!where) return { problem: 'The type definitions that come with the extension are missing (bundled\\types).' };
  if (!modsDir) return { problem: 'No mods folder was found.' };
  const mods = scanMods(modsDir);
  const byId = new Map(mods.map((mod) => [mod.id, mod.dir]));
  const changed = [];
  for (const mod of mods) {
    const absolute = !(where.live && isInside(where.root, mod.dir));
    const settings = luarc.settingsFor({ dir: mod.dir, types: where.types, plugin: where.plugin, mods: byId, absolute });
    if (luarc.write(mod.dir, settings)) changed.push(path.join(mod.dir, '.luarc.json'));
    luarc.writeFiles(mod.dir, mod.files);
  }
  for (const folder of folders) {
    if (mods.some((mod) => samePath(mod.dir, folder))) continue;
    const file = path.join(folder, '.luarc.json');
    if (fs.existsSync(file) && !isOurs(file)) continue;
    const settings = folderSettings(folder, modsDir, where);
    if (settings && luarc.write(folder, settings)) changed.push(file);
  }
  return { mods, changed, where };
}

module.exports = { locate, isOurs, folderSettings, setUp };
