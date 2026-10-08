#!/usr/bin/env node
// The store on the station from the command line, from the game's exported tables: list it, and check a store a mod describes
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const LUA = path.join(ROOT, 'tools', 'lua', 'lua54', 'lua.exe');
const OFFLINE = path.join(ROOT, 'wax', 'cli', 'workshop_offline.lua');
const SAMPLE = 40; // rows of other trees kept with --store-only, so a reader still has something to leave out
const LIMIT_MS = 120000; // a store file is somebody's Lua, and one that never ends is stopped

const FILES = {
  TalentArchetypes: 'Talents/D_TalentArchetypes.json',
  TalentTrees: 'Talents/D_TalentTrees.json',
  Talents: 'Talents/D_Talents.json',
  WorkshopItems: 'MetaWorkshop/D_WorkshopItems.json',
  ItemTemplate: 'Items/D_ItemTemplate.json',
  ItemsStatic: 'Items/D_ItemsStatic.json',
  Itemable: 'Traits/D_Itemable.json',
  MetaCurrency: 'Currency/D_MetaCurrency.json',
  AccountFlags: 'Flags/D_AccountFlags.json',
  DLCPackageData: 'DLC/D_DLCPackageData.json',
};

// The numbers the running game gives for these names (ETalentNodeType, ELineDrawMethod, EFlagsTableType).
const TALENT_TYPE = { Talent: 0, Reroute: 1, MutuallyExclusive: 2 };
const LINE = { Unspecified: 0, NoLine: 1, ShortestDistance: 2, XThenY: 3, YThenX: 4 };
const FLAG_TABLE = { D_CharacterFlags: 0, D_SessionFlags: 1, D_AccountFlags: 2, D_DLCPackageData: 3 };

class Problem extends Error {}

const fold = (name) => String(name).toLowerCase();
const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

function findFile(dataDir, relative) {
  const direct = path.join(dataDir, relative);
  if (fs.existsSync(direct)) return direct;
  // a game update may move a table to another folder
  const wanted = path.basename(relative);
  for (const entry of fs.readdirSync(dataDir, { withFileTypes: true, recursive: true })) {
    if (entry.isFile() && entry.name === wanted) return path.join(entry.parentPath ?? entry.path, entry.name);
  }
  throw new Problem(`${wanted} is not in ${dataDir}. Run scripts\\Export-GameData.ps1, or name the folder with --data.`);
}

// A row with what the table's Defaults say for everything the row leaves out.
function filled(defaults, row) {
  if (!isObject(row)) return row;
  const out = {};
  for (const key of new Set([...Object.keys(isObject(defaults) ? defaults : {}), ...Object.keys(row)])) {
    const mine = row[key];
    const base = isObject(defaults) ? defaults[key] : undefined;
    out[key] = mine === undefined ? base : isObject(mine) && isObject(base) ? filled(base, mine) : mine;
  }
  return out;
}

function readTable(dataDir, name) {
  const data = JSON.parse(fs.readFileSync(findFile(dataDir, FILES[name]), 'utf8'));
  if (!Array.isArray(data.Rows)) throw new Problem(`${FILES[name]} has no rows.`);
  return data.Rows.map((row) => filled(data.Defaults, row));
}

// The text the game shows for a text field of the tables.
function shownText(value) {
  if (typeof value !== 'string') return '';
  const found = /^NSLOCTEXT\(\s*"(?:[^"\\]|\\.)*"\s*,\s*"(?:[^"\\]|\\.)*"\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)$/s.exec(value)
    ?? /^INVTEXT\(\s*"((?:[^"\\]|\\.)*)"\s*\)$/s.exec(value);
  if (!found) return value;
  return found[1].replace(/\\(.)/g, (_all, escaped) => ({ n: '\n', r: '\r', t: '\t' })[escaped] ?? escaped);
}

const asset = (value) => (typeof value === 'string' && value !== '' && value !== 'None' ? value : undefined);
const handle = (value) => ({ RowName: isObject(value) && typeof value.RowName === 'string' ? value.RowName : 'None' });
const place = (value) => ({ X: Number(value?.X ?? 0), Y: Number(value?.Y ?? 0) });

function numbered(names, value, what) {
  if (typeof value === 'number') return value;
  if (!(value in names)) throw new Problem(`The tables use ${what} "${value}", which this tool does not know. The game may have been updated.`);
  return names[value];
}

const PICK = {
  TalentArchetypes: (row) => ({
    Model: handle(row.Model), DisplayName: shownText(row.DisplayName), Icon: asset(row.Icon), RequiredLevel: row.RequiredLevel ?? 0,
  }),
  TalentTrees: (row) => ({ Archetype: handle(row.Archetype), BackgroundTexture: asset(row.BackgroundTexture) }),
  Talents: (row) => ({
    TalentType: numbered(TALENT_TYPE, row.TalentType ?? 'Talent', 'the node type'),
    ExtraData: handle(row.ExtraData),
    TalentTree: handle(row.TalentTree),
    position: place(row.Position),
    Size: place(row.Size),
    RequiredTalents: (row.RequiredTalents ?? []).map(handle),
    RequiredFlags: (row.RequiredFlags ?? []).map((flag) => ({
      RowName: flag.RowName,
      DataTableName: flag.DataTableName === undefined ? undefined : numbered(FLAG_TABLE, flag.DataTableName, 'the flag table'),
    })),
    RequiredLevel: row.RequiredLevel ?? 0,
    bDefaultUnlocked: row.bDefaultUnlocked === true,
    DrawMethodOverride: numbered(LINE, row.DrawMethodOverride ?? 'Unspecified', 'the line style'),
  }),
  WorkshopItems: (row) => ({
    Item: handle(row.Item),
    ResearchCost: (row.ResearchCost ?? []).map((cost) => ({ Meta: handle(cost.Meta), Amount: cost.Amount ?? 0 })),
    ReplicationCost: (row.ReplicationCost ?? []).map((cost) => ({ Meta: handle(cost.Meta), Amount: cost.Amount ?? 0 })),
  }),
  ItemTemplate: (row) => ({ ItemStaticData: handle(row.ItemStaticData) }),
  ItemsStatic: (row) => ({ Itemable: handle(row.Itemable) }),
  Itemable: (row) => ({ DisplayName: shownText(row.DisplayName), Icon: asset(row.Icon), MaxStack: row.MaxStack ?? 0 }),
  MetaCurrency: (row) => ({
    DisplayName: shownText(row.DisplayName), Icon: asset(row.Icon), bDisplayOnMainScreen: row.bDisplayOnMainScreen === true,
  }),
  AccountFlags: () => ({}),
  DLCPackageData: () => ({}),
};

// The store's rows out of the game's tables, shaped as the running game hands them out. storeOnly keeps what the store reaches, for the test fixture.
export function extract(dataDir, { storeOnly = false } = {}) {
  if (!fs.existsSync(dataDir)) {
    throw new Problem(`The game's tables are not in ${dataDir}. Run scripts\\Export-GameData.ps1, or name the folder with --data.`);
  }
  const raw = Object.fromEntries(Object.keys(FILES).map((name) => [name, readTable(dataDir, name)]));
  const named = (row) => (isObject(row) && typeof row.RowName === 'string' && fold(row.RowName) !== 'none' ? fold(row.RowName) : null);

  const categories = new Set(raw.TalentArchetypes.filter((row) => named(row.Model) === 'workshop').map((row) => fold(row.Name)));
  const trees = new Set(raw.TalentTrees.filter((row) => categories.has(named(row.Archetype))).map((row) => fold(row.Name)));
  const keep = { Talents: [], ItemTemplate: raw.ItemTemplate, ItemsStatic: raw.ItemsStatic, Itemable: raw.Itemable };
  let others = 0;
  for (const row of raw.Talents) {
    if (trees.has(named(row.TalentTree))) keep.Talents.push(row);
    else if (!storeOnly || others++ < SAMPLE) keep.Talents.push({ ...row, light: true });
  }
  if (storeOnly) {
    const templates = new Set(raw.WorkshopItems.map((row) => named(row.Item)));
    keep.ItemTemplate = raw.ItemTemplate.filter((row) => templates.has(fold(row.Name)));
    const statics = new Set(keep.ItemTemplate.map((row) => named(row.ItemStaticData)));
    keep.ItemsStatic = raw.ItemsStatic.filter((row) => statics.has(fold(row.Name)));
    const itemables = new Set(keep.ItemsStatic.map((row) => named(row.Itemable)));
    keep.Itemable = raw.Itemable.filter((row) => itemables.has(fold(row.Name)));
  }

  const tables = {};
  for (const name of Object.keys(FILES)) {
    const rows = (keep[name] ?? raw[name]).map((row) => {
      // a node of another tree is only told apart by its tree
      const picked = row.light ? { TalentTree: handle(row.TalentTree) } : PICK[name](row);
      return { name: row.Name, fields: picked, light: row.light === true };
    });
    tables[name] = { rows };
  }
  return tables;
}

function luaString(text) {
  return '"' + text.replace(/[\\"\n\r\0]/g, (c) => ({ '\\': '\\\\', '"': '\\"', '\n': '\\n', '\r': '\\r', '\0': '\\0' })[c]) + '"';
}

const ITEM_ICONS = '/Game/Assets/2DArt/UI/Items/Item_Icons/';

// A value as Lua text. What repeats a lot is written through the short functions at the top of the file.
function lua(value) {
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  if (typeof value === 'string') {
    const twice = /^(\/.+\/([^/.]+))\.\2$/.exec(value);
    if (!twice) return luaString(value);
    return twice[1].startsWith(ITEM_ICONS) ? `i(${luaString(twice[1].slice(ITEM_ICONS.length))})` : `a(${luaString(twice[1])})`;
  }
  if (Array.isArray(value)) return value.length ? `{ ${value.map(lua).join(', ')} }` : '{}';
  const keys = Object.keys(value).filter((key) => value[key] !== undefined);
  const only = (...names) => keys.length === names.length && names.every((name) => keys.includes(name));
  if (only('RowName')) return `h(${luaString(value.RowName)})`;
  if (only('X', 'Y')) return `p(${lua(value.X)}, ${lua(value.Y)})`;
  if (only('Meta', 'Amount') && Object.keys(value.Meta).length === 1) return `c(${luaString(value.Meta.RowName)}, ${lua(value.Amount)})`;
  return keys.length ? `{ ${keys.map((key) => `${key} = ${lua(value[key])}`).join(', ')} }` : '{}';
}

// The rows as a Lua file. What most rows of a table say is written once, as that table's defaults.
export function luaText(tables, madeBy = 'extract') {
  const lines = [
    '-- Rows of the game\'s tables for the store, shaped as the running game hands them out. Do not edit.',
    `-- Made by: node wax/cli/workshop.mjs ${madeBy}`,
    'local function h(name) return { RowName = name } end',
    'local function p(x, y) return { X = x, Y = y } end',
    'local function c(currency, amount) return { Meta = { RowName = currency }, Amount = amount } end',
    'local function a(path) return path .. "." .. path:match("[^/]+$") end',
    `local function i(path) return a(${luaString(ITEM_ICONS)} .. path) end`,
    '',
    'return {',
  ];
  for (const [name, table] of Object.entries(tables)) {
    const full = table.rows.filter((row) => !row.light);
    const defaults = {};
    for (const field of Object.keys(full[0]?.fields ?? {})) {
      const counts = new Map();
      for (const row of full) {
        const text = JSON.stringify(row.fields[field]) ?? '';
        counts.set(text, (counts.get(text) ?? 0) + 1);
      }
      const [most] = [...counts.entries()].sort((one, other) => other[1] - one[1])[0] ?? [];
      if (most) defaults[field] = JSON.parse(most);
    }
    lines.push(`    ${name} = {`, `        defaults = ${lua(defaults)},`, '        rows = {');
    for (const row of table.rows) {
      const parts = [luaString(row.name)];
      for (const [field, value] of Object.entries(row.fields)) {
        if (value === undefined) {
          if (defaults[field] !== undefined) parts.push(`${field} = false`);
        } else if (JSON.stringify(value) !== JSON.stringify(defaults[field])) {
          parts.push(`${field} = ${lua(value)}`);
        }
      }
      lines.push(`            { ${parts.join(', ')} },`);
    }
    lines.push('        },', '    },');
  }
  lines.push('}', '');
  return lines.join('\n');
}

function option(args, name, fallback) {
  const at = args.indexOf(name);
  if (at === -1) return fallback;
  const value = args[at + 1];
  args.splice(at, 2);
  return value;
}

function flag(args, name) {
  const at = args.indexOf(name);
  if (at === -1) return false;
  args.splice(at, 1);
  return true;
}

// The id of the mod a store file belongs to: the folder it is in, when that folder is a mod.
function modOf(file) {
  const dir = path.dirname(path.resolve(file));
  return fs.existsSync(path.join(dir, 'mod.lua')) || fs.existsSync(path.join(dir, 'init.lua')) ? path.basename(dir) : undefined;
}

function runOffline(dataDir, parts) {
  if (!fs.existsSync(LUA)) throw new Problem('tools\\lua\\lua54\\lua.exe is missing. Run scripts\\Get-Tools.ps1.');
  const rows = path.join(ROOT, 'build', 'workshop', 'rows.lua');
  fs.mkdirSync(path.dirname(rows), { recursive: true });
  const slashed = (file) => file.replaceAll('\\', '/');
  let done;
  try {
    fs.writeFileSync(rows, luaText(extract(dataDir)));
    done = spawnSync(LUA, [OFFLINE, slashed(ROOT), slashed(rows), ...parts.filter((part) => part !== undefined)],
      { cwd: ROOT, stdio: 'inherit', timeout: LIMIT_MS });
  } finally {
    fs.rmSync(rows, { force: true });
  }
  if (done.error?.code === 'ETIMEDOUT') throw new Problem(`It did not end within ${LIMIT_MS / 1000} seconds and was stopped.`);
  if (done.error) throw new Problem(`Lua could not be started: ${done.error.message}`);
  return done.status ?? 1;
}

const USAGE = `usage:
  workshop.mjs list [category]              the store's categories, or the nodes of one
  workshop.mjs check [store.lua] [--mod Id] what is wrong with a store file. Without a file: the loose ends of the game's own store
  workshop.mjs extract --out file.lua [--store-only]   the store's rows as a Lua file
options:
  --data <folder>   the game's exported tables. game-data\\data of this workspace when omitted`;

async function main() {
  const args = process.argv.slice(2);
  const command = args.shift();
  const dataDir = path.resolve(option(args, '--data', path.join(ROOT, 'game-data', 'data')));
  switch (command) {
    case 'list':
      return runOffline(dataDir, ['list', args[0]]);
    case 'check': {
      const mod = option(args, '--mod');
      const file = args[0];
      if (file === undefined) return runOffline(dataDir, ['check']);
      if (!fs.existsSync(file)) throw new Problem(`${file} is not there.`);
      // the file by its full path, the mod's id or nothing, the file as it was typed, for what is printed, and where the id is from
      const folder = mod === undefined ? modOf(file) : undefined;
      return runOffline(dataDir, ['check', path.resolve(file).replaceAll('\\', '/'), mod ?? folder ?? '', file, folder === undefined ? 'given' : 'folder']);
    }
    case 'extract': {
      const out = option(args, '--out');
      const storeOnly = flag(args, '--store-only');
      if (!out) throw new Problem('extract needs --out <file.lua>.');
      const text = luaText(extract(dataDir, { storeOnly }), storeOnly ? 'extract --store-only --out <file>' : 'extract --out <file>');
      fs.mkdirSync(path.dirname(path.resolve(out)), { recursive: true });
      fs.writeFileSync(out, text);
      console.log(`${out}: ${(text.length / 1024).toFixed(0)} KB`);
      return 0;
    }
    default:
      console.error(USAGE);
      return 2;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exit(await main());
  } catch (error) {
    if (!(error instanceof Problem)) throw error;
    console.error(error.message);
    process.exit(1);
  }
}
