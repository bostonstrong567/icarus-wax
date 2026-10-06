'use strict';
// require("...") in a mod: what can be completed, what the game's loader would refuse, and how to fix the manifest
const { mask } = require('./luatext');
const { dependenciesIn } = require('./luarc');

// The require being typed at the end of `before` (a line up to the cursor): { partial, start }, or null.
function requireContext(before) {
  const match = /(?<![\w.:])require\s*\(?\s*(["'])([^"']*)$/.exec(mask(before));
  if (!match) return null;
  return { partial: match[2], start: before.length - match[2].length };
}

// The names a mod's own files answer to, as the loader resolves them (<name>.lua, then <name>/init.lua): { name, file }.
function moduleNames(mod, separator = '.') {
  const skip = new Set(['init.lua', 'mod.lua', mod.main || 'init.lua']);
  const out = [];
  for (const file of mod.files) {
    if (skip.has(file)) continue;
    const stem = file.slice(0, -4);
    if (stem.includes('.')) continue;
    const parts = stem.split('/');
    const folder = parts.slice(0, -1);
    if (parts[parts.length - 1] === 'init' && !mod.files.includes(folder.join('/') + '.lua')) {
      out.push({ name: folder.join(separator), file });
    } else {
      out.push({ name: parts.join(separator), file });
    }
  }
  return out;
}

// What to offer inside require("..."). mod: the mod the file is in. mods: every mod in the folder.
function requireCandidates({ mod, mods = [], partial = '' }) {
  if (!mod) return [];
  const out = [];
  if (!partial.startsWith('@')) {
    const separator = partial.includes('/') ? '/' : '.';
    for (const entry of moduleNames(mod, separator)) out.push({ label: entry.name, kind: 'module', detail: entry.file, file: entry.file });
  }
  for (const other of mods) {
    if (other.id === mod.id) continue;
    const declared = mod.dependencies.includes(other.id);
    out.push({
      label: '@' + other.id, kind: 'mod', declared, dependency: other.id,
      detail: declared ? `${other.name}: what its init.lua returns` : `${other.name}: needs "${other.id}" under dependencies in mod.lua`,
    });
  }
  return out;
}

// Every require of a literal name outside comments: { name, start, end } with offsets into the text.
function findRequires(text) {
  const found = [];
  for (const match of mask(text).matchAll(/(?<![\w.:])require\s*\(?\s*(["'])([^"'\n]*)\1/g)) {
    const start = match.index + match[0].length - 1 - match[2].length;
    found.push({ name: match[2], start, end: start + match[2].length });
  }
  return found;
}

function resolveModule(mod, name) {
  const relative = name.replace(/\./g, '/');
  if (mod.files.includes(relative + '.lua')) return relative + '.lua';
  if (mod.files.includes(relative + '/init.lua')) return relative + '/init.lua';
  return null;
}

// The requires the loader would raise an error for, in its own words: { code, name, start, end, message, dependency }.
function checkRequires({ text, mod, mods = [] }) {
  const problems = [];
  for (const use of findRequires(text)) {
    if (!use.name || use.name === 'init') continue;
    if (use.name.startsWith('@')) {
      const id = use.name.slice(1);
      if (!mods.some((other) => other.id === id)) {
        problems.push({ ...use, code: 'not-installed', message: `mod '${id}' is not installed (required by ${mod.id})` });
      } else if (!mod.dependencies.includes(id)) {
        problems.push({
          ...use, code: 'undeclared', dependency: id,
          message: `${mod.id} uses require("@${id}") but does not list "${id}" under dependencies in its mod.lua`,
        });
      }
    } else if (!resolveModule(mod, use.name)) {
      const relative = use.name.replace(/\./g, '/');
      problems.push({
        ...use, code: 'missing-module',
        message: `module '${use.name}' not found in ${mod.id} (looked for ${relative}.lua and ${relative}/init.lua)`,
      });
    }
  }
  return problems;
}

function closingBrace(clean, open) {
  let depth = 0;
  for (let i = open; i < clean.length; i++) {
    if (clean[i] === '{') depth++;
    else if (clean[i] === '}' && --depth === 0) return i;
  }
  return -1;
}

// Puts `addition` after the last item of the table whose braces are at open..close.
function appendToTable(text, clean, open, close, addition) {
  let last = close - 1;
  while (last > open && /\s/.test(clean[last])) last--;
  if (last === open) {
    const inner = text.slice(open + 1, close);
    if (inner.includes('\n')) {
      const indent = /^[ \t]*/.exec(text.slice(text.lastIndexOf('\n', open) + 1))[0];
      return text.slice(0, open + 1) + '\n' + indent + '    ' + addition + ',' + (inner.trim() ? inner : '\n' + indent) + text.slice(close);
    }
    return text.slice(0, open + 1) + ' ' + addition + (inner.trim() ? ',' : '') + (inner || ' ') + text.slice(close);
  }
  const comma = clean[last] === ',';
  if (text.slice(open, last + 1).includes('\n')) {
    const indent = /^[ \t]*/.exec(text.slice(text.lastIndexOf('\n', last) + 1))[0];
    return text.slice(0, last + 1) + (comma ? '' : ',') + '\n' + indent + addition + ',' + text.slice(last + 1);
  }
  return text.slice(0, last + 1) + (comma ? ' ' : ', ') + addition + text.slice(last + 1);
}

// The manifest's text with `id` added under dependencies. Null when the text is not a shape this can edit safely.
function addDependency(manifest, id) {
  const entry = `"${id}"`;
  if (manifest === null || manifest === undefined || !manifest.trim()) return `return {\n    dependencies = { ${entry} },\n}\n`;
  if (dependenciesIn(manifest).includes(id)) return manifest;
  const clean = mask(manifest, { strings: true });
  const list = /\bdependencies\s*=\s*\{/.exec(clean);
  if (list) {
    const open = list.index + list[0].length - 1;
    const close = closingBrace(clean, open);
    return close === -1 ? null : appendToTable(manifest, clean, open, close, entry);
  }
  const table = /\breturn\s*\{/.exec(clean);
  if (!table) return null;
  const open = table.index + table[0].length - 1;
  const close = closingBrace(clean, open);
  return close === -1 ? null : appendToTable(manifest, clean, open, close, `dependencies = { ${entry} }`);
}

module.exports = { requireContext, moduleNames, requireCandidates, findRequires, resolveModule, checkRequires, addDependency };
