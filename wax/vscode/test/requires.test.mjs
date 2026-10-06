// require("..."): completion, the check against what the game's loader accepts, and the manifest fix
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
import { require, scratch, put, LUA } from './helpers.mjs';

const requires = require('../lib/requires.js');
const { dependenciesIn } = require('../lib/luarc.js');
const { mask, luaString, luaValue } = require('../lib/luatext.js');

const mod = {
  id: 'Hello', name: 'Hello', dir: 'X:/mods/Hello', main: 'init.lua', dependencies: ['Base'],
  files: ['init.lua', 'mod.lua', 'util.lua', 'gui/init.lua', 'gui/panel.lua', 'data/items.lua', 'both.lua', 'both/init.lua', 'odd.name.lua', 'v1.2/x.lua'],
};
const mods = [
  mod,
  { id: 'Base', name: 'Base Library', dir: 'X:/mods/Base', main: 'init.lua', dependencies: [], files: ['init.lua'] },
  { id: 'Other', name: 'Other', dir: 'X:/mods/Other', main: 'init.lua', dependencies: [], files: ['init.lua'] },
];

test('completion starts inside the quotes of a require, in any of the ways Lua lets it be written', () => {
  assert.deepEqual(requires.requireContext('local util = require("'), { partial: '', start: 22 });
  assert.deepEqual(requires.requireContext('local util = require("gui.pa'), { partial: 'gui.pa', start: 22 });
  assert.deepEqual(requires.requireContext("require '@Ba"), { partial: '@Ba', start: 9 });
  assert.deepEqual(requires.requireContext('x = require ( "a'), { partial: 'a', start: 15 });
  assert.equal(requires.requireContext('print("require'), null);
  assert.equal(requires.requireContext('local x = require("done") .. "'), null);
  assert.equal(requires.requireContext('-- require("'), null);
  assert.equal(requires.requireContext('my.require("'), null);
  assert.equal(requires.requireContext('prerequire("'), null);
  assert.equal(requires.requireContext('require('), null);
});

test('a mod\'s own modules are offered in the form the loader takes', () => {
  const names = requires.moduleNames(mod);
  assert.deepEqual(names, [
    { name: 'util', file: 'util.lua' },
    { name: 'gui', file: 'gui/init.lua' },
    { name: 'gui.panel', file: 'gui/panel.lua' },
    { name: 'data.items', file: 'data/items.lua' },
    { name: 'both', file: 'both.lua' },
    { name: 'both.init', file: 'both/init.lua' },
  ]);
  // every offered name resolves, to the file it was offered for
  for (const entry of names) assert.equal(requires.resolveModule(mod, entry.name), entry.file, entry.name);
  for (const entry of requires.moduleNames(mod, '/')) assert.equal(requires.resolveModule(mod, entry.name), entry.file, entry.name);
  assert.deepEqual(requires.moduleNames(mod, '/').map((entry) => entry.name), ['util', 'gui', 'gui/panel', 'data/items', 'both', 'both/init']);
});

test('the entry point, the manifest and files with a dot in their name are not offered', () => {
  const names = requires.moduleNames(mod).map((entry) => entry.name);
  for (const never of ['init', 'mod', 'odd.name', 'v1.2.x']) assert.ok(!names.includes(never), never);
  const custom = { ...mod, main: 'main.lua', files: ['main.lua', 'mod.lua', 'init.lua', 'a.lua'] };
  assert.deepEqual(requires.moduleNames(custom).map((entry) => entry.name), ['a']);
});

test('other mods are offered as @Id, saying whether the manifest lists them', () => {
  const offered = requires.requireCandidates({ mod, mods, partial: '' });
  assert.deepEqual(offered.filter((c) => c.kind === 'module').map((c) => c.label), ['util', 'gui', 'gui.panel', 'data.items', 'both', 'both.init']);
  assert.deepEqual(offered.filter((c) => c.kind === 'mod').map((c) => [c.label, c.declared]), [['@Base', true], ['@Other', false]]);
  assert.match(offered.find((c) => c.label === '@Other').detail, /dependencies/);

  assert.deepEqual(requires.requireCandidates({ mod, mods, partial: '@' }).map((c) => c.label), ['@Base', '@Other']);
  assert.ok(requires.requireCandidates({ mod, mods, partial: 'gui/' }).some((c) => c.label === 'gui/panel'));
  assert.deepEqual(requires.requireCandidates({ mod: null, mods, partial: '' }), []);
});

test('requires are found where they are code, not where they are comments or text', () => {
  const text = [
    'local a = require("util")',
    '-- local b = require("commented")',
    'local c = require \'gui.panel\'',
    '--[[ require("blocked")',
    'require("also blocked") ]]',
    'local d = require(name)',
    'local e = other.require("not ours")',
    'local f = require ( "@Base" )',
  ].join('\n');
  const found = requires.findRequires(text);
  assert.deepEqual(found.map((use) => use.name), ['util', 'gui.panel', '@Base']);
  for (const use of found) assert.equal(text.slice(use.start, use.end), use.name);
});

test('what the loader would refuse is reported in its own words', () => {
  const text = [
    'local util = require("util")',
    'local gui = require("gui")',
    'local base = require("@Base")',
    'local other = require("@Other")',
    'local gone = require("@Gone")',
    'local typo = require("utli")',
    'local deep = require("data.missing")',
    'local self = require("init")',
    'local empty = require("")',
  ].join('\n');
  const problems = requires.checkRequires({ text, mod, mods });
  assert.deepEqual(problems.map((p) => [p.code, p.name]), [
    ['undeclared', '@Other'], ['not-installed', '@Gone'], ['missing-module', 'utli'], ['missing-module', 'data.missing'],
  ]);
  assert.equal(problems[0].message, 'Hello uses require("@Other") but does not list "Other" under dependencies in its mod.lua');
  assert.equal(problems[0].dependency, 'Other');
  assert.equal(problems[1].message, "mod 'Gone' is not installed (required by Hello)");
  assert.equal(problems[3].message, "module 'data.missing' not found in Hello (looked for data/missing.lua and data/missing/init.lua)");
  assert.equal(text.slice(problems[2].start, problems[2].end), 'utli');
});

const manifests = {
  'no manifest at all': [null, 'return {\n    dependencies = { "X" },\n}\n'],
  'no dependencies yet': ['return {\n    name = "Hello",\n    version = "0.1.0",\n}\n', 'return {\n    name = "Hello",\n    version = "0.1.0",\n    dependencies = { "X" },\n}\n'],
  'no trailing comma': ['return {\n    name = "Hello"\n}\n', 'return {\n    name = "Hello",\n    dependencies = { "X" },\n}\n'],
  'one line': ['return { name = "Hello" }\n', 'return { name = "Hello", dependencies = { "X" } }\n'],
  'empty table': ['return {}\n', 'return { dependencies = { "X" } }\n'],
  'empty over two lines': ['return {\n}\n', 'return {\n    dependencies = { "X" },\n}\n'],
  'empty list': ['return { dependencies = {} }\n', 'return { dependencies = { "X" } }\n'],
  'a list with one': ['return {\n    dependencies = { "A" },\n}\n', 'return {\n    dependencies = { "A", "X" },\n}\n'],
  'a list ending in a comma': ['return { dependencies = { "A", } }\n', 'return { dependencies = { "A", "X" } }\n'],
  'a list over several lines': ['return {\n    dependencies = {\n        "A",\n        "B"\n    },\n}\n', 'return {\n    dependencies = {\n        "A",\n        "B",\n        "X",\n    },\n}\n'],
  'a comment after the last field': ['return {\n    name = "Hello", -- shown in the menu\n}\n', 'return {\n    name = "Hello",\n    dependencies = { "X" }, -- shown in the menu\n}\n'],
  'a brace inside a string': ['return {\n    name = "a } b",\n}\n', 'return {\n    name = "a } b",\n    dependencies = { "X" },\n}\n'],
  'a commented-out list': ['return {\n    name = "Hello",\n    -- dependencies = { "Old" },\n}\n', 'return {\n    name = "Hello",\n    dependencies = { "X" },\n    -- dependencies = { "Old" },\n}\n'],
};

test('a dependency is added to a manifest of any usual shape', () => {
  for (const [what, [before, after]] of Object.entries(manifests)) {
    assert.equal(requires.addDependency(before, 'X'), after, what);
    assert.ok(dependenciesIn(after).includes('X'), what);
  }
  const listed = 'return { dependencies = { "X" } }\n';
  assert.equal(requires.addDependency(listed, 'X'), listed, 'already there');
  assert.equal(requires.addDependency('local m = {}\nm.name = "odd"\nreturn m\n', 'X'), null, 'a shape that is left alone');
  assert.equal(requires.addDependency('return { dependencies = { "A"', 'X'), null, 'an unfinished file');
});

test('the edited manifests still load in Lua and list the dependency', { skip: !fs.existsSync(LUA) && 'standalone Lua is not installed' }, (t) => {
  const dir = scratch(t);
  const files = { 'check.lua': 'for i = 1, #arg do\n    local m = dofile(arg[i])\n    local found = false\n    for _, id in ipairs(m.dependencies) do found = found or id == "X" end\n    assert(found, arg[i])\nend\nprint(#arg)\n' };
  const list = Object.values(manifests).map(([, after], index) => {
    files[`m${index}.lua`] = after;
    return `m${index}.lua`;
  });
  put(dir, files);
  assert.equal(execFileSync(LUA, ['check.lua', ...list], { cwd: dir, encoding: 'utf8' }).trim(), String(list.length));
});

test('masking blanks comments and keeps every offset', () => {
  const text = 'a = "x -- y" -- gone\nb = [[ long ]] --[==[ block\nstill ]==] c = 1';
  const masked = mask(text);
  assert.equal(masked.length, text.length);
  assert.equal(masked, 'a = "x -- y"        \nb = [[ long ]]             \n           c = 1');
  assert.equal(mask(text, { strings: true }), 'a = "      "        \nb = [[      ]]             \n           c = 1');
  assert.equal(mask('s = "a\\"b" -- c'), 's = "a\\"b"     ');
});

test('values are written as Lua literals that read back the same', { skip: !fs.existsSync(LUA) && 'standalone Lua is not installed' }, (t) => {
  assert.equal(luaValue(null), 'nil');
  assert.equal(luaValue(undefined), 'nil');
  assert.equal(luaValue(true), 'true');
  assert.equal(luaValue(-2.5), '-2.5');
  assert.throws(() => luaValue(NaN));
  assert.throws(() => luaValue({}));
  const tricky = 'line one\r\nline "two" \\ back\\slash\ttab \u00e9\u4e2d \x001 end';
  const dir = scratch(t);
  put(dir, {
    'value.lua': `return ${luaString(tricky)}\n`,
    'check.lua': 'local f = assert(io.open("out.bin", "wb"))\nf:write(dofile("value.lua"))\nf:close()\n',
  });
  execFileSync(LUA, ['check.lua'], { cwd: dir });
  assert.equal(fs.readFileSync(`${dir}/out.bin`, 'utf8'), tricky);
});
