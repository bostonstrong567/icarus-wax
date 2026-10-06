'use strict';
// Names for new mods and new module files

const MOD_ID = /^[A-Za-z][A-Za-z0-9_]*$/;
const SEGMENT = /^[A-Za-z_][A-Za-z0-9_-]*$/;
const MAX_ID = 48;
// Windows will not make files or folders with these names.
const DEVICES = new Set(['con', 'prn', 'aux', 'nul',
  'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
  'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9']);
// Log channels the framework uses for itself.
const CHANNELS = new Set(['wax', 'console']);

// "my cool mod" -> "MyCoolMod". A name that is already a valid id is kept as typed.
function modIdFrom(name) {
  const text = String(name ?? '').trim();
  if (MOD_ID.test(text)) return text;
  const words = text.split(/[^A-Za-z0-9]+/).filter(Boolean);
  const id = words.map((word) => word[0].toUpperCase() + word.slice(1)).join('');
  return id.replace(/^[0-9_]+/, '');
}

// Returns what is wrong with the name of a new mod, or null. existing: ids already in the mods folder.
function modNameProblem(name, existing = []) {
  const text = String(name ?? '').trim();
  if (!text) return 'Give the mod a name.';
  const id = modIdFrom(text);
  if (!id) return 'The name needs at least one letter.';
  if (!MOD_ID.test(id)) return 'Use letters, digits and _ only, starting with a letter.';
  if (id.length > MAX_ID) return `The folder name "${id}" is too long (${MAX_ID} characters at most).`;
  if (DEVICES.has(id.toLowerCase()) || CHANNELS.has(id.toLowerCase())) return `"${id}" is a reserved name. Pick another.`;
  if (existing.some((other) => other.toLowerCase() === id.toLowerCase())) return `A mod named "${id}" already exists.`;
  return null;
}

// "sub.util", "sub/util" or "sub\util.lua" -> { name: "sub.util", file: "sub/util.lua", segments }. Null when unusable.
function parseModuleName(input) {
  let text = String(input ?? '').trim().replace(/\\/g, '/');
  if (/\.lua$/i.test(text)) text = text.slice(0, -4);
  if (!text) return null;
  const segments = text.split(/[./]/);
  if (segments.some((segment) => !SEGMENT.test(segment))) return null;
  return { name: segments.join('.'), file: segments.join('/') + '.lua', segments };
}

// Returns what is wrong with the name of a new module file, or null. files: the mod's files, as "sub/util.lua".
function moduleNameProblem(input, files = []) {
  if (!String(input ?? '').trim()) return 'Give the script a name, such as util or sub.util.';
  const parsed = parseModuleName(input);
  if (!parsed) return 'Use letters, digits, _ and - only. A dot or a slash puts the file in a folder.';
  if (parsed.segments.some((segment) => DEVICES.has(segment.toLowerCase()))) return 'Windows does not allow a file or folder with that name.';
  if (parsed.file === 'init.lua') return 'init.lua is the mod itself. Pick another name.';
  if (parsed.file === 'mod.lua') return 'mod.lua is the mod\'s manifest. Pick another name.';
  const taken = new Set(files.map((file) => file.toLowerCase()));
  if (taken.has(parsed.file.toLowerCase())) return `${parsed.file} already exists.`;
  const folderForm = parsed.segments.join('/') + '/init.lua';
  if (taken.has(folderForm.toLowerCase())) return `${folderForm} already answers to require("${parsed.name}").`;
  return null;
}

// A Lua identifier for the module's table, taken from the last part of its name.
function identifierFor(moduleName) {
  const last = moduleName.split('.').pop().replace(/[^A-Za-z0-9_]/g, '_');
  const keywords = new Set(['and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for', 'function', 'goto', 'if', 'in',
    'local', 'nil', 'not', 'or', 'repeat', 'return', 'then', 'true', 'until', 'while']);
  if (keywords.has(last) || /^[0-9]/.test(last)) return 'M';
  return last;
}

module.exports = { MOD_ID, modIdFrom, modNameProblem, parseModuleName, moduleNameProblem, identifierFor };
