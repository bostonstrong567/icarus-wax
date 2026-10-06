// New Mod and New Script: names and the files they start as
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { require, scratch, put, read, LUA, LANGUAGE_SERVER, EXTENSION, ROOT } from './helpers.mjs';

const names = require('../lib/names.js');
const templates = require('../lib/templates.js');
const { scanMods } = require('../lib/mods.js');
const support = require('../lib/support.js');

test('a mod id comes from the name typed', () => {
  assert.equal(names.modIdFrom('Hello'), 'Hello');
  assert.equal(names.modIdFrom('my_mod2'), 'my_mod2');
  assert.equal(names.modIdFrom('my cool mod'), 'MyCoolMod');
  assert.equal(names.modIdFrom('  Bob\'s  auto-loot! '), 'BobSAutoLoot');
  assert.equal(names.modIdFrom('2 fast'), 'Fast');
  assert.equal(names.modIdFrom('!!!'), '');
});

test('names the game or Windows would refuse are turned down with a reason', () => {
  assert.equal(names.modNameProblem('My Mod'), null);
  assert.match(names.modNameProblem(''), /name/);
  assert.match(names.modNameProblem('   '), /name/);
  assert.match(names.modNameProblem('123'), /letter/);
  assert.match(names.modNameProblem('con'), /reserved/);
  assert.match(names.modNameProblem('Console'), /reserved/);
  assert.match(names.modNameProblem('x'.repeat(60)), /too long/);
  assert.match(names.modNameProblem('hello', ['Hello']), /already exists/);
  assert.match(names.modNameProblem('My Mod', ['other', 'MYMOD']), /already exists/);
});

test('every id the name check lets through is one the game and the command-line tool accept', () => {
  for (const name of ['A', 'my cool mod', 'Über mod 3', 'x_1', 'a-b']) {
    assert.equal(names.modNameProblem(name), null, name);
    assert.match(names.modIdFrom(name), /^[A-Za-z][A-Za-z0-9_]*$/, name);
  }
});

test('a module name becomes a file, with dots or slashes for folders', () => {
  assert.deepEqual(names.parseModuleName('util'), { name: 'util', file: 'util.lua', segments: ['util'] });
  assert.deepEqual(names.parseModuleName('sub.util'), { name: 'sub.util', file: 'sub/util.lua', segments: ['sub', 'util'] });
  assert.equal(names.parseModuleName('sub/util').name, 'sub.util');
  assert.equal(names.parseModuleName('sub\\util.lua').file, 'sub/util.lua');
  assert.equal(names.parseModuleName('bad name'), null);
  assert.equal(names.parseModuleName('a..b'), null);
  assert.equal(names.parseModuleName('../escape'), null);
});

test('a module name that cannot be used says why', () => {
  const files = ['init.lua', 'mod.lua', 'util.lua', 'gui/init.lua'];
  assert.equal(names.moduleNameProblem('helpers', files), null);
  assert.equal(names.moduleNameProblem('gui.panel', files), null);
  assert.match(names.moduleNameProblem('', files), /name/);
  assert.match(names.moduleNameProblem('init', files), /the mod itself/);
  assert.match(names.moduleNameProblem('mod', files), /manifest/);
  assert.match(names.moduleNameProblem('Util', files), /already exists/);
  assert.match(names.moduleNameProblem('gui', files), /already answers/);
  assert.match(names.moduleNameProblem('nul', files), /Windows/);
  assert.match(names.moduleNameProblem('a b', files), /letters/);
});

test('New Mod writes mod.lua and init.lua and never touches a folder that is there', (t) => {
  const modsDir = path.join(scratch(t), 'mods');
  const made = templates.createMod(modsDir, 'My "Cool" Mod', { description: '  Counts  the trees\nI cut. ', start: 'window' });
  assert.equal(made.id, 'MyCoolMod');
  assert.equal(made.dir, path.join(modsDir, 'MyCoolMod'));
  assert.equal(read(made.manifest), 'return {\n    name = "My \\"Cool\\" Mod",\n    description = "Counts the trees I cut.",\n    version = "0.1.0",\n}\n');
  assert.match(read(made.init), /ui\.Window\(\{ title = "My \\"Cool\\" Mod"/);
  assert.match(read(made.init), /MyCoolMod\/init\.lua/);

  const [mod] = scanMods(modsDir);
  assert.equal(mod.id, 'MyCoolMod');
  assert.equal(mod.name, 'My "Cool" Mod');
  assert.equal(mod.description, 'Counts the trees I cut.');
  assert.equal(mod.version, '0.1.0');

  const before = read(made.init);
  assert.throws(() => templates.createMod(modsDir, 'mycoolmod'), /already exists/);
  assert.throws(() => templates.createMod(modsDir, 'My Cool Mod', { start: 'empty' }), /already exists/);
  assert.equal(read(made.init), before);
});

test('a mod made without a description has none in mod.lua, and starts as a window unless told otherwise', (t) => {
  const modsDir = scratch(t);
  const plain = templates.createMod(modsDir, 'Plain');
  assert.equal(read(plain.manifest), 'return {\n    name = "Plain",\n    version = "0.1.0",\n}\n');
  assert.equal(read(plain.init), templates.initText('Plain', 'Plain', 'window'));
  assert.equal(read(templates.createMod(modsDir, 'Blank', { description: '   ' }).manifest), 'return {\n    name = "Blank",\n    version = "0.1.0",\n}\n');
});

test('New Mod offers three starting points, and each makes its own init.lua', (t) => {
  assert.deepEqual(templates.STARTS.map((start) => start.label), ['Empty', 'Window with a button', 'Overlay']);
  assert.deepEqual(templates.STARTS.map((start) => start.id), ['empty', 'window', 'overlay']);
  const modsDir = scratch(t);
  const texts = {};
  for (const start of templates.STARTS) {
    assert.ok(start.detail.endsWith('.'), start.id);
    const made = templates.createMod(modsDir, `Try ${start.id}`, { start: start.id });
    texts[start.id] = read(made.init);
    assert.equal(made.start, start.id);
    assert.ok(texts[start.id].startsWith(`-- Try ${start.id}. `), start.id);
    assert.ok(texts[start.id].split('\n').length <= 12, `${start.id} is short enough to read at a glance`);
  }
  assert.match(texts.empty, /^print\("Try empty loaded"\)$/m);
  assert.ok(!/\bui\./.test(texts.empty));
  assert.match(texts.window, /ui\.Window\(/);
  assert.match(texts.window, /window:Button\("Say hello"/);
  assert.match(texts.overlay, /ui\.Overlay\(/);
  assert.ok(!/ui\.Window\(/.test(texts.overlay));

  // a starting point that does not exist stops before anything is written
  assert.throws(() => templates.createMod(modsDir, 'Unknown Start', { start: 'nope' }), /no starting point/);
  assert.ok(!fs.existsSync(path.join(modsDir, 'UnknownStart')));
});

test('New Script writes a module and never overwrites one', (t) => {
  const dir = scratch(t);
  put(dir, { 'init.lua': 'return {}\n' });
  const made = templates.createModule(dir, 'sub.util', ['init.lua']);
  assert.equal(made.name, 'sub.util');
  assert.equal(made.file, path.join(dir, 'sub', 'util.lua'));
  assert.match(read(made.file), /local util = \{\}/);
  assert.match(read(made.file), /require\(mod\.sub\.util\)/);
  assert.match(read(made.file), /return util\n$/);
  assert.throws(() => templates.createModule(dir, 'sub.util', ['init.lua', 'sub/util.lua']), /already exists/);
  // the list of files given was stale: the file on disk still wins
  assert.throws(() => templates.createModule(dir, 'sub/util', ['init.lua']), /EEXIST/);
  assert.match(templates.moduleText('do'), /local M = \{\}/);
});

test('the templates are valid Lua', { skip: !fs.existsSync(LUA) && 'standalone Lua is not installed' }, (t) => {
  const dir = scratch(t);
  const awkward = 'It\'s "quoted"\\ and long';
  const files = { 'mod.lua': templates.manifestText(awkward, 'Says "hi"\\ too'), 'util.lua': templates.moduleText('sub.my-util') };
  for (const start of templates.STARTS) files[`${start.id}.lua`] = templates.initText('Quoted', awkward, start.id);
  put(dir, {
    ...files,
    'check.lua': 'for i = 1, #arg do assert(loadfile(arg[i])) end\nlocal m = dofile(arg[1])\nassert(m.name == [[It\'s "quoted"\\ and long]], m.name)\nassert(m.description == [[Says "hi"\\ too]], m.description)\nprint("ok")\n',
  });
  const out = execFileSync(LUA, ['check.lua', ...Object.keys(files)], { cwd: dir, encoding: 'utf8' });
  assert.equal(out.trim(), 'ok');
});

// A snippet's body as the Lua it leaves when every placeholder keeps its default.
const expand = (body) => body.join('\n')
  .replace(/\$\{\d+\|([^,|}]*)[^}]*\}/g, '$1')
  .replace(/\$\{\d+:([^}]*)\}/g, '$1')
  .replace(/\$\d+/g, '')
  .replaceAll('\t', '    ');

const snippets = Object.entries(JSON.parse(read(path.join(EXTENSION, 'snippets', 'wax.json'))));

// Every name Wax's definitions give a mod: ui.Window, task.wait, game.MapName, and the methods of its objects.
function definedNames() {
  const functions = new Set();
  const members = new Set();
  const dir = path.join(ROOT, 'wax', 'types');
  for (const file of fs.readdirSync(dir).filter((name) => name.endsWith('.lua'))) {
    // the fields of the class being described; a global declared right after them has them
    let fields = [];
    for (const line of read(path.join(dir, file)).split(/\r?\n/)) {
      const made = /^function (\w+)[.:](\w+)\(/.exec(line);
      const field = /^---@field (\w+)/.exec(line);
      const global = /^(\w+) = \{\}/.exec(line);
      if (/^---@class /.test(line)) fields = [];
      if (field) {
        fields.push(field[1]);
        members.add(field[1]);
      }
      if (global) for (const name of fields) functions.add(`${global[1]}.${name}`);
      if (made) {
        functions.add(`${made[1]}.${made[2]}`);
        members.add(made[2]);
      }
    }
  }
  return { functions, members };
}

test('the templates and the snippets use only what Wax\'s definitions have', () => {
  const { functions, members } = definedNames();
  for (const known of ['ui.Window', 'ui.Notify', 'task.wait', 'storage.Load', 'game.MapName', 'game.MapChanged']) assert.ok(functions.has(known), known);
  const sources = [
    ...templates.STARTS.map((start) => [`the ${start.id} starting point`, templates.initText('Mod', 'Mod', start.id)]),
    ...snippets.map(([name, snippet]) => [name, expand(snippet.body)]),
  ];
  for (const [name, text] of sources) {
    for (const use of text.matchAll(/\b(ui|game|task|storage|Signal|mod|log)\.(\w+)/g)) assert.ok(functions.has(`${use[1]}.${use[2]}`), `${name}: ${use[0]}`);
    for (const use of text.matchAll(/:(\w+)\(/g)) assert.ok(members.has(use[1]), `${name}: :${use[1]}()`);
  }
  assert.ok(!functions.has('ui.NoSuchThing'));
});

test('the language server finds nothing wrong with the templates or the snippets',
  { skip: !fs.existsSync(LANGUAGE_SERVER) && 'the Lua language server is not installed' }, (t) => {
    const base = scratch(t);
    const modsDir = path.join(base, 'mods');
    for (const start of templates.STARTS) templates.createMod(modsDir, `Start ${start.id}`, { description: 'A test.', start: start.id });
    // each snippet in a file of its own, after the window the control snippets add to
    const files = { 'Snippets/init.lua': 'return {}\n' };
    snippets.forEach(([, snippet], index) => {
      const body = expand(snippet.body);
      const window = /^window:/m.test(body) && !/^local window\b/m.test(body) ? 'local window = ui.Window({ title = "Test" })\n' : '';
      files[`Snippets/s${index}_${snippet.prefix.slice(4)}.lua`] = `${window}${body}\n`;
    });
    put(modsDir, files);
    const made = support.setUp({ folders: [modsDir], modsDir, extensionDir: EXTENSION });
    assert.equal(made.problem, undefined);
    const check = () => spawnSync(LANGUAGE_SERVER, ['--check', modsDir, '--checklevel=Warning',
      `--logpath=${path.join(base, 'log')}`, `--metapath=${path.join(base, 'meta')}`], { encoding: 'utf8' });
    const clean = check();
    assert.match(clean.stdout, /no problems found/, clean.stdout.slice(-3000));
    // the same check does catch a name Wax does not have
    put(modsDir, { 'Snippets/wrong.lua': 'ui.NoSuchThing()\n' });
    assert.match(check().stdout, /1 problems found/);
  });

test('a script is loaded as mod.<name> when Lua can write the name after a dot, else by its name in quotes', () => {
  assert.equal(names.requireText('Utils'), 'require(mod.Utils)');
  assert.equal(names.requireText('extras.Utils'), 'require(mod.extras.Utils)');
  assert.equal(names.requireText('my-file'), 'require("my-file")');
  assert.equal(names.requireText('extras.2nd'), 'require("extras.2nd")');
});
