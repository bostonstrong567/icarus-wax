// Finds mod folders and writes the index the game reads in developer mode
import fs from 'node:fs';
import path from 'node:path';
import { ROOT, RUN, evalLua, gameRunning } from './bridge.mjs';

const INDEX = path.join(RUN, 'mods.index.lua');
const ID_PATTERN = /^[A-Za-z][A-Za-z0-9_]*$/;

// Folders whose subfolders are mods. Extra roots can be listed in wax/wax.config.json as "modRoots".
export function modRoots() {
  let extra = [];
  try {
    extra = JSON.parse(fs.readFileSync(path.join(ROOT, 'wax', 'wax.config.json'), 'utf8')).modRoots ?? [];
  } catch {}
  return [path.join(ROOT, 'luamods'), ...extra];
}

function listLuaFiles(dir, prefix = '') {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith('.')) continue;
    const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isDirectory()) out.push(...listLuaFiles(path.join(dir, entry.name), relative));
    else if (entry.name.endsWith('.lua')) out.push(relative);
  }
  return out.sort();
}

export function scanMods() {
  const mods = [];
  const skipped = [];
  for (const root of modRoots()) {
    if (!fs.existsSync(root)) continue;
    for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
      if (!entry.isDirectory() || entry.name.startsWith('.') || entry.name.startsWith('_')) continue;
      const dir = path.join(root, entry.name);
      const files = listLuaFiles(dir);
      if (!files.includes('init.lua') && !files.includes('mod.lua')) continue;
      if (!ID_PATTERN.test(entry.name)) {
        skipped.push(`${entry.name}: a mod folder name must start with a letter and use only letters, digits and _`);
        continue;
      }
      if (mods.some((m) => m.id === entry.name)) {
        skipped.push(`${entry.name}: a mod with this name was already found in another root`);
        continue;
      }
      mods.push({ id: entry.name, dir: dir.replaceAll('\\', '/'), files });
    }
  }
  mods.sort((a, b) => a.id.localeCompare(b.id));
  return { mods, skipped };
}

// A Lua string literal. JSON escapes are not all valid Lua, so only the characters that need it are escaped.
function luaString(text) {
  return '"' + text.replace(/[\\"\n\r\0]/g, (c) => ({ '\\': '\\\\', '"': '\\"', '\n': '\\n', '\r': '\\r', '\0': '\\0' })[c]) + '"';
}

function indexText(mods) {
  const lines = ['-- Written by the Wax command-line tool. Do not edit: it is regenerated whenever mod files change.', 'return { mods = {'];
  for (const mod of mods) {
    lines.push(`  { id = ${luaString(mod.id)}, dir = ${luaString(mod.dir)}, files = { ${mod.files.map(luaString).join(', ')} } },`);
  }
  lines.push('} }', '');
  return lines.join('\n');
}

// Writes the index if it changed. Returns { mods, skipped, changed }.
export function writeIndex() {
  const { mods, skipped } = scanMods();
  const text = indexText(mods);
  let changed = true;
  try { changed = fs.readFileSync(INDEX, 'utf8') !== text; } catch {}
  if (changed) {
    fs.mkdirSync(RUN, { recursive: true });
    fs.writeFileSync(INDEX + '.part', text);
    fs.renameSync(INDEX + '.part', INDEX);
  }
  return { mods, skipped, changed };
}

const REPORT = `
local since, accepted = ...
local out = { mods = Wax.mods.list(), errors = {}, accepted = accepted }
for _, entry in ipairs(Wax.log.since(since, { level = "warn" })) do
    out.errors[#out.errors + 1] = { level = entry.level, channel = entry.channel, message = entry.message }
end
return out`;

// Tells the running game to pick up the index, switch on those of acceptIds it has not seen (it holds every new mod otherwise) and reload reloadIds. Returns the game's reply.
export async function applyInGame(reloadIds = [], acceptIds = []) {
  if (!gameRunning()) return { ok: false, error: 'the game is not running' };
  const ids = reloadIds.map(luaString).join(', ');
  const accept = acceptIds.map(luaString).join(', ');
  return evalLua(`
if not (rawget(_G, "Wax") and Wax.mods) then error("the Wax core is not running in the game") end
local since = Wax.log.newest_id()
Wax.mods.sync()
local accepted = {}
for _, id in ipairs({ ${accept} }) do
    local mod = Wax.mods.get(id)
    -- a copy the site's button put in (it carries wax.new) is left for the player to switch on
    if mod and mod.fresh and not mod.mark and Wax.mods.set_enabled(id, true) then accepted[#accepted + 1] = id end
end
if #accepted > 0 then Wax.mods.sync() end
for _, id in ipairs({ ${ids} }) do Wax.mods.reload(id) end
return (function(...) ${REPORT} end)(since, accepted)`, { timeoutSec: 30 });
}

function describe(reply, started, { withErrors = true } = {}) {
  if (!reply.ok) return `  ! ${reply.error}`;
  const { mods, errors, accepted } = reply.values[0];
  const lines = [];
  if (Array.isArray(accepted) && accepted.length) lines.push(`  new to the game, switched on: ${accepted.join(', ')}`);
  for (const mod of Array.isArray(mods) ? mods : []) {
    const mark = mod.status === 'loaded' ? 'ok ' : '!! ';
    const held = mod.fresh ? ' (new: the game holds it until it is switched on in the Mods page)' : '';
    lines.push(`  ${mark}${mod.id} ${mod.version ?? ''} ${mod.status}${held}${mod.error ? ': ' + mod.error : ''}`);
  }
  if (withErrors) {
    for (const e of Array.isArray(errors) ? errors : []) lines.push(`  [${e.level}] ${e.channel}: ${String(e.message).split('\n').slice(0, 6).join('\n      ')}`);
  }
  lines.push(`  (${Math.round(performance.now() - started)} ms)`);
  return lines.join('\n');
}

export async function sync() {
  const started = performance.now();
  const { mods, skipped } = writeIndex();
  for (const note of skipped) console.log(`  skipped ${note}`);
  console.log(`${mods.length} mod(s) indexed: ${mods.map((m) => m.id).join(', ') || 'none'}`);
  // what this tool lists is the developer's own work, so a mod the game has not seen is switched on by it
  const reply = await applyInGame([], mods.map((mod) => mod.id));
  console.log(describe(reply, started));
  return reply;
}

// Prints what the game logged since the last call (mod print() output, warnings, errors). Returns the newest id.
async function printNewLog(afterId) {
  const reply = await evalLua(`
if not (rawget(_G, "Wax") and Wax.log) then return { newest = 0, entries = {} } end
local entries = {}
for _, e in ipairs(Wax.log.since(${afterId})) do
    entries[#entries + 1] = { level = e.level, channel = e.channel, message = e.message }
end
return { newest = Wax.log.newest_id(), entries = entries }`, { timeoutSec: 3 });
  if (!reply.ok) return afterId;
  const { newest, entries } = reply.values[0];
  for (const e of Array.isArray(entries) ? entries : []) {
    const tag = e.level === 'info' ? '' : `${e.level.toUpperCase()} `;
    console.log(`  ${tag}[${e.channel}] ${e.message}`);
  }
  // A smaller id means the core was restarted; start again from its beginning.
  return newest;
}

// Watches the mod roots; a saved file reloads its mod in the running game
export async function watch() {
  await sync();
  const pending = new Set();
  let timer = null;
  let busy = false;
  let lastLogId = 0;
  const first = await evalLua('return rawget(_G, "Wax") and Wax.log and Wax.log.newest_id() or 0', { timeoutSec: 10 });
  if (first.ok) lastLogId = first.values[0];

  const flush = async () => {
    timer = null;
    if (busy) { timer = setTimeout(flush, 60); return; }
    busy = true;
    try {
      const ids = [...pending];
      pending.clear();
      const started = performance.now();
      writeIndex();
      console.log(`\n${new Date().toLocaleTimeString()}  changed: ${ids.join(', ')}`);
      const reply = await applyInGame(ids, ids);
      // Everything the reload logged (the mod's own prints, any error with its traceback), then the verdict.
      if (reply.ok) lastLogId = await printNewLog(lastLogId);
      console.log(describe(reply, started, { withErrors: false }));
    } finally {
      busy = false;
    }
  };

  setInterval(async () => {
    if (busy) return;
    busy = true;
    try { lastLogId = await printNewLog(lastLogId); } finally { busy = false; }
  }, 1000);
  for (const root of modRoots()) {
    if (!fs.existsSync(root)) fs.mkdirSync(root, { recursive: true });
    fs.watch(root, { recursive: true }, (_event, file) => {
      if (!file || !file.endsWith('.lua')) return;
      const id = file.split(/[\\/]/)[0];
      if (!ID_PATTERN.test(id)) return;
      pending.add(id);
      // Editors write a file in several steps; wait for the burst to finish.
      clearTimeout(timer);
      timer = setTimeout(flush, 60);
    });
    console.log(`watching ${root}`);
  }
  console.log('Save a .lua file in a mod folder to reload it in the game. Ctrl+C to stop.');
  await new Promise(() => {});
}
