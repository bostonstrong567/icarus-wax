// Editor support: what goes into .luarc.json, where the definitions come from, and that the language server accepts it
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { require, scratch, put, read, makeRuntime, ROOT, EXTENSION, LANGUAGE_SERVER } from './helpers.mjs';

const luarc = require('../lib/luarc.js');
const support = require('../lib/support.js');
const templates = require('../lib/templates.js');

const json = (file) => JSON.parse(read(file));

// An extension folder as it is once packed: the definitions and the plugin under bundled.
function makeExtension(dir) {
  put(dir, { 'bundled/types/ui.lua': '---@meta _\n', 'bundled/lsp/plugin.lua': '-- plugin\n' });
  return dir;
}

test('a mod in this workspace gets the file the command-line tool writes', () => {
  const dir = path.join(ROOT, 'luamods', 'Hello');
  const settings = luarc.settingsFor({
    dir, types: path.join(ROOT, 'wax', 'types'), plugin: path.join(ROOT, 'wax', 'lsp', 'plugin.lua'),
    mods: new Map([['Hello', dir]]),
  });
  assert.deepEqual(settings, {
    'runtime.version': 'Lua 5.4',
    'runtime.builtin': { basic: 'disable' },
    'runtime.plugin': '../../wax/lsp/plugin.lua',
    'workspace.library': ['../../wax/types'],
    'workspace.checkThirdParty': 'Disable',
    'diagnostics.disable': ['lowercase-global'],
  });
  const written = path.join(dir, '.luarc.json');
  if (fs.existsSync(written)) assert.equal(luarc.textFor(settings), read(written));
});

test('a mod sees the mods it depends on, and only those', (t) => {
  const modsDir = scratch(t);
  put(modsDir, {
    'App/mod.lua': 'return { dependencies = { "Base", "Missing" } }\n',
    'App/init.lua': 'return {}\n',
    'Base/init.lua': 'return {}\n',
    'Unrelated/init.lua': 'return {}\n',
  });
  const mods = new Map(['App', 'Base', 'Unrelated'].map((id) => [id, path.join(modsDir, id)]));
  const settings = luarc.settingsFor({ dir: mods.get('App'), types: path.join(modsDir, '..', 'types'), plugin: path.join(modsDir, '..', 'plugin.lua'), mods });
  assert.deepEqual(settings['workspace.library'], ['../../types', '../Base']);
  assert.deepEqual(luarc.dependenciesOf(mods.get('App')), ['Base', 'Missing']);
  assert.deepEqual(luarc.dependenciesOf(mods.get('Base')), []);
});

test('definitions outside the workspace are written as full paths', () => {
  const settings = luarc.settingsFor({ dir: 'D:\\Games\\Wax\\mods\\App', types: 'C:\\Users\\me\\.vscode\\extensions\\wax\\bundled\\types',
    plugin: 'C:\\Users\\me\\.vscode\\extensions\\wax\\bundled\\lsp\\plugin.lua', absolute: true });
  assert.equal(settings['runtime.plugin'], 'C:/Users/me/.vscode/extensions/wax/bundled/lsp/plugin.lua');
  assert.deepEqual(settings['workspace.library'], ['C:/Users/me/.vscode/extensions/wax/bundled/types']);
});

test('the file is only written when it would change', (t) => {
  const dir = scratch(t);
  const settings = luarc.settingsFor({ dir, types: path.join(dir, 'types'), plugin: path.join(dir, 'plugin.lua') });
  assert.equal(luarc.write(dir, settings), true);
  assert.equal(luarc.write(dir, settings), false);
  assert.equal(read(path.join(dir, '.luarc.json')), luarc.textFor(settings));
  assert.match(read(path.join(dir, '.luarc.json')), /^\{\n    "runtime\.version": "Lua 5\.4",/);
  settings['workspace.library'].push('../Other');
  assert.equal(luarc.write(dir, settings), true);
});

test('the workspace\'s own definitions win over the ones packed into the extension', (t) => {
  const base = scratch(t);
  const extension = makeExtension(path.join(base, 'extension'));
  assert.deepEqual(support.locate({ folders: [ROOT], extensionDir: extension }),
    { types: path.join(ROOT, 'wax', 'types'), plugin: path.join(ROOT, 'wax', 'lsp', 'plugin.lua'), live: true, root: ROOT });
  assert.deepEqual(support.locate({ folders: [base], extensionDir: extension }),
    { types: path.join(extension, 'bundled', 'types'), plugin: path.join(extension, 'bundled', 'lsp', 'plugin.lua'), live: false, root: null });
  assert.equal(support.locate({ folders: [base], extensionDir: path.join(base, 'nothing', 'here') }), null);
  // run from a source checkout: the originals next to the extension, built or not
  assert.equal(support.locate({ folders: [], extensionDir: EXTENSION }).plugin, path.join(ROOT, 'wax', 'lsp', 'plugin.lua'));
});

test('on a player\'s machine every mod, and the open mods folder, point into the extension', (t) => {
  const base = scratch(t);
  const extension = makeExtension(path.join(base, 'ext-0.1.0'));
  const runtime = makeRuntime(path.join(base, 'Wax'));
  const modsDir = path.join(runtime, 'mods');
  put(modsDir, {
    'Base/init.lua': 'return {}\n',
    'App/init.lua': 'return {}\n',
    'App/mod.lua': 'return { dependencies = { "Base" } }\n',
  });
  const first = support.setUp({ folders: [modsDir], modsDir, extensionDir: extension });
  assert.equal(first.problem, undefined);
  assert.deepEqual(first.mods.map((mod) => mod.id), ['App', 'Base']);
  assert.deepEqual(first.changed.map((file) => path.relative(modsDir, file)).sort(), ['.luarc.json', 'App\\.luarc.json', 'Base\\.luarc.json']);

  const slashed = (file) => file.split(path.sep).join('/');
  const app = json(path.join(modsDir, 'App', '.luarc.json'));
  assert.equal(app['runtime.plugin'], slashed(path.join(extension, 'bundled', 'lsp', 'plugin.lua')));
  assert.deepEqual(app['workspace.library'], [slashed(path.join(extension, 'bundled', 'types')), '../Base']);
  assert.deepEqual(json(path.join(modsDir, '.luarc.json'))['workspace.library'], [slashed(path.join(extension, 'bundled', 'types'))]);

  // nothing to do the second time
  assert.deepEqual(support.setUp({ folders: [modsDir], modsDir, extensionDir: extension }).changed, []);

  // an update of the extension moves its folder: every file follows, the folder's own included
  const updated = makeExtension(path.join(base, 'ext-0.2.0'));
  assert.equal(support.setUp({ folders: [modsDir], modsDir, extensionDir: updated }).changed.length, 3);
  assert.equal(json(path.join(modsDir, '.luarc.json'))['runtime.plugin'], slashed(path.join(updated, 'bundled', 'lsp', 'plugin.lua')));
});

test('a .luarc.json the user wrote for the folder is left alone', (t) => {
  const base = scratch(t);
  const extension = makeExtension(path.join(base, 'ext'));
  const modsDir = path.join(base, 'mods');
  const own = '{ "runtime.version": "Lua 5.4", "runtime.plugin": "my/plugin.lua" }\n';
  put(modsDir, { 'App/init.lua': 'return {}\n', '.luarc.json': own });
  const result = support.setUp({ folders: [modsDir], modsDir, extensionDir: extension });
  assert.equal(result.changed.length, 1);
  assert.equal(read(path.join(modsDir, '.luarc.json')), own);
  assert.equal(support.isOurs(path.join(modsDir, '.luarc.json')), false);
  assert.equal(support.isOurs(path.join(modsDir, 'App', '.luarc.json')), true);
});

test('with the whole Wax folder open, only its mods are the user\'s code', (t) => {
  const base = scratch(t);
  const extension = makeExtension(path.join(base, 'ext'));
  const runtime = makeRuntime(path.join(base, 'Wax'));
  put(runtime, { 'mods/App/init.lua': 'return {}\n', 'Scripts/wax/boot.lua': 'return {}\n', 'run/session.log': '', 'saved/x.lua': 'return {}\n' });
  const modsDir = path.join(runtime, 'mods');
  support.setUp({ folders: [runtime], modsDir, extensionDir: extension });
  assert.deepEqual(json(path.join(runtime, '.luarc.json'))['workspace.ignoreDir'], ['Scripts', 'run', 'saved']);
});

test('a folder that only happens to contain the mods folder gets nothing', (t) => {
  const base = scratch(t);
  const extension = makeExtension(path.join(base, 'ext'));
  put(base, { 'project/luamods/App/init.lua': 'return {}\n' });
  const project = path.join(base, 'project');
  const result = support.setUp({ folders: [project], modsDir: path.join(project, 'luamods'), extensionDir: extension });
  assert.deepEqual(result.changed, [path.join(project, 'luamods', 'App', '.luarc.json')]);
  assert.equal(fs.existsSync(path.join(project, '.luarc.json')), false);
});

test('a mod folder opened by itself is not given a second file', (t) => {
  const base = scratch(t);
  const extension = makeExtension(path.join(base, 'ext'));
  const modsDir = path.join(base, 'mods');
  put(modsDir, { 'App/init.lua': 'return {}\n' });
  const result = support.setUp({ folders: [path.join(modsDir, 'App')], modsDir, extensionDir: extension });
  assert.deepEqual(result.changed, [path.join(modsDir, 'App', '.luarc.json')]);
});

test('what is missing is said plainly', (t) => {
  const base = scratch(t);
  assert.match(support.setUp({ folders: [base], modsDir: base, extensionDir: path.join(base, 'none') }).problem, /definitions/);
  assert.match(support.setUp({ folders: [base], modsDir: null, extensionDir: makeExtension(path.join(base, 'ext')) }).problem, /mods folder/);
});

// A snippet body as it stands once every placeholder has its default.
function expand(body) {
  return body.join('\n')
    .replace(/\$\{\d+\|([^,|]*)[^}]*\|\}/g, '$1')
    .replace(/\$\{\d+:([^}]*)\}/g, '$1')
    .replace(/\$\d+/g, '');
}

test('the language server finds nothing wrong with a new mod, a new script and every snippet',
  { skip: !fs.existsSync(LANGUAGE_SERVER) && 'the Lua language server is not installed (scripts\\Get-Tools.ps1)' }, (t) => {
    const base = scratch(t);
    const modsDir = path.join(base, 'mods');
    const made = templates.createMod(modsDir, 'Check Me');
    templates.createModule(made.dir, 'sub.util', []);
    const snippets = json(path.join(EXTENSION, 'snippets', 'wax.json'));
    const code = ['local util = require("sub.util")', 'util.hello()', ...Object.values(snippets).map((snippet) => expand(snippet.body))];
    put(made.dir, { 'snippets.lua': code.join('\n') + '\n' });
    assert.ok(!/\$\{|\$\d/.test(read(path.join(made.dir, 'snippets.lua'))), 'a placeholder was left in');
    const result = support.setUp({ folders: [ROOT], modsDir, extensionDir: EXTENSION });
    assert.equal(result.where.live, true);

    const check = (dir) => spawnSync(LANGUAGE_SERVER, ['--check', dir, '--checklevel=Warning',
      `--logpath=${path.join(base, 'log')}`, `--metapath=${path.join(base, 'meta')}`], { encoding: 'utf8' });
    const clean = check(made.dir);
    assert.match(clean.stdout, /no problems found/, clean.stdout.slice(-3000));

    // and it is really checking against the definitions: a made-up function is caught
    put(made.dir, { 'wrong.lua': 'ui.NoSuchThing()\nui.Notify("x", { kind = "purple" })\n' });
    const caught = check(made.dir);
    assert.match(caught.stdout, /2 problems found/, caught.stdout.slice(-3000));
    fs.rmSync(path.join(made.dir, 'wrong.lua'));

    // members of game have the game's own classes; a member or a class the list lacks is still accepted
    put(made.dir, { 'typed.lua': [
      'local me = game.Character',
      'if me then print(me.ActorState.CurrentAliveState, me.NotListed, me:IsValid()) end',
      'local other = game:Find("BP_NotListed_C")',
      'if other then print(other.Anything, other.Name) end',
      'local state = game:Find("IcarusPlayerState")',
      'if state then print(state:GetPlayerName()) end',
      'for _, wolf in ipairs(game.Creatures:GetAll("Wolf")) do game.Highlight:Add(wolf) end',
    ].join('\n') + '\n' });
    const typed = check(made.dir);
    assert.match(typed.stdout, /no problems found/, typed.stdout.slice(-3000));
    put(made.dir, { 'typed.lua': '---@type string\nlocal wrong = game.LocalPlayer.PlayerCameraManager\nprint(wrong)\n'
      + '---@type string\nlocal also = game:Find("IcarusPlayerCharacter")\nprint(also)\n' });
    const mistyped = check(made.dir);
    assert.match(mistyped.stdout, /2 problems found/, mistyped.stdout.slice(-3000));
    fs.rmSync(path.join(made.dir, 'typed.lua'));

    // the plugin makes require("@Other") mean the other mod: what it returns is known, so a field it lacks is caught
    put(modsDir, {
      'Base/init.lua': '---@class BaseExports\nlocal base = {}\n\nfunction base.greet() return "hi" end\n\nreturn base\n',
      'CheckMe/mod.lua': 'return { name = "Check Me", dependencies = { "Base" } }\n',
      'CheckMe/uses.lua': 'local base = require("@Base")\nprint(base.greet())\nprint(base.nothing())\n',
    });
    support.setUp({ folders: [ROOT], modsDir, extensionDir: EXTENSION });
    const across = check(made.dir);
    assert.match(across.stdout, /1 problems found/, across.stdout.slice(-3000));
    assert.match(across.stdout, /nothing/);

    // mod.<file> and mod.<folder>.<file>: the names complete from the list Wax writes, and the plugin lets the server
    // follow require(mod.x) into the file, so both a file that is not there and a function it lacks are caught
    fs.rmSync(path.join(made.dir, 'uses.lua'));
    put(made.dir, {
      'Utils.lua': '---@class CheckMeUtils\nlocal Utils = {}\n\nfunction Utils.add(a, b) return a + b end\n\nreturn Utils\n',
      'extras/Deep.lua': 'local Deep = {}\n\nfunction Deep.name() return "deep" end\n\nreturn Deep\n',
      'tidy.lua': 'local Utils = require(mod.Utils)\nlocal Deep = require(mod.extras.Deep)\nprint(Utils.add(1, 2), Deep.name(), mod.id)\n',
    });
    support.setUp({ folders: [ROOT], modsDir, extensionDir: EXTENSION });
    const listed = read(path.join(made.dir, '.wax', 'files.lua'));
    assert.match(listed, /---@field Utils WaxFile Utils\.lua/);
    assert.match(listed, /---@field extras WaxFolder\.CheckMe\.extras /);
    assert.match(listed, /---@class WaxFolder\.CheckMe\.extras\n---@field Deep WaxFile extras\/Deep\.lua/);
    assert.ok(!/@field (init|mod|id) /.test(listed), listed);
    const tidy = check(made.dir);
    assert.match(tidy.stdout, /no problems found/, tidy.stdout.slice(-3000));
    put(made.dir, { 'untidy.lua': 'local Utils = require(mod.Utils)\nprint(Utils.nothing())\nprint(mod.extras.Nope)\n' });
    const untidy = check(made.dir);
    assert.match(untidy.stdout, /2 problems found/, untidy.stdout.slice(-3000));
    fs.rmSync(path.join(made.dir, 'untidy.lua'));

    // without the plugin the server cannot tell what "@Base" is, and says nothing
    put(made.dir, { 'uses.lua': 'local base = require("@Base")\nprint(base.greet())\nprint(base.nothing())\n' });
    fs.rmSync(path.join(made.dir, 'tidy.lua'));
    const file = path.join(made.dir, '.luarc.json');
    const settings = json(file);
    delete settings['runtime.plugin'];
    fs.writeFileSync(file, luarc.textFor(settings));
    assert.match(check(made.dir).stdout, /no problems found/);
  });
