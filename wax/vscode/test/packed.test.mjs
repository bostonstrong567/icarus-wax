// The built .vsix, unpacked somewhere with no workspace around it: what a player's machine gets
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { require, scratch, put, read, makeRuntime, writeIndex, startStandInGame, ROOT, EXTENSION, LUA, LANGUAGE_SERVER } from './helpers.mjs';

const fakeVscode = require('./fake-vscode.cjs');
const { version } = require('../package.json');
const VSIX = path.join(ROOT, 'build', `wax-icarus-${version}.vsix`);
const TAR = path.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'tar.exe');

const walk = (dir, prefix = '') => fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
  (entry.isDirectory() ? walk(path.join(dir, entry.name), `${prefix}${entry.name}/`) : [`${prefix}${entry.name}`]));

// Where a packed file came from in the workspace.
function sourceOf(packed) {
  if (packed === 'bundled/bridge.mjs') return path.join(ROOT, 'wax', 'cli', 'bridge.mjs');
  if (packed === 'bundled/lsp/plugin.lua') return path.join(ROOT, 'wax', 'lsp', 'plugin.lua');
  if (packed.startsWith('bundled/types/')) return path.join(ROOT, 'wax', 'types', packed.slice('bundled/types/'.length));
  if (packed === 'readme.md') return path.join(EXTENSION, 'README.md');
  return path.join(EXTENSION, packed);
}

// The reason the package cannot be tested, or null. A package older than its sources is not tested as if it were current.
function unusable(extension) {
  const packed = walk(extension);
  const sources = ['extension.js', 'package.json', ...['lib', 'lua', 'snippets'].flatMap((dir) => walk(path.join(EXTENSION, dir), `${dir}/`)),
    ...walk(path.join(ROOT, 'wax', 'types')).map((name) => `bundled/types/${name}`)];
  for (const file of sources) {
    if (!packed.includes(file)) return `${file} is not in the package`;
  }
  for (const file of packed) {
    const source = sourceOf(file);
    if (!fs.existsSync(source) || !fs.readFileSync(source).equals(fs.readFileSync(path.join(extension, file)))) return `${file} has changed since the package was built`;
  }
  return null;
}

const missing = !fs.existsSync(VSIX) ? `build\\wax-icarus-${version}.vsix is not built (scripts\\Build-WaxExtension.ps1)`
  : !fs.existsSync(TAR) ? 'tar.exe is needed to unpack the .vsix' : false;

test('the packed extension', { skip: missing }, async (t) => {
  const base = scratch(t);
  const unpacked = path.join(base, 'unpacked');
  fs.mkdirSync(unpacked);
  execFileSync(TAR, ['-xf', VSIX, '-C', unpacked]);
  const extension = path.join(unpacked, 'extension');
  const stale = unusable(extension);
  if (stale) {
    t.skip(`the package is out of date (${stale}); run scripts\\Build-WaxExtension.ps1`);
    return;
  }

  await t.test('holds what it needs and none of the tests', () => {
    const files = walk(extension);
    for (const needed of ['extension.js', 'package.json', 'icon.png', 'readme.md', 'media/wax.svg', 'snippets/wax.json', 'lua/run.lua',
      'lib/game.js', 'lib/docs.js', 'lib/features/view.js', 'lib/features/locate.js', 'bundled/bridge.mjs', 'bundled/lsp/plugin.lua', 'bundled/types/ui.lua', 'bundled/types/lua_basic.lua']) {
      assert.ok(files.includes(needed), needed);
    }
    assert.deepEqual(files.filter((file) => file.startsWith('test/') || file.endsWith('.py') || file.includes('node_modules')), []);
    const identity = read(path.join(unpacked, 'extension.vsixmanifest'));
    assert.match(identity, /<Identity[^>]*Id="wax-icarus"[^>]*Publisher="RobertCincotta"/);
    assert.match(identity, /ExtensionDependencies" Value="sumneko\.lua"/);
    assert.match(identity, /<DisplayName>Wax for Icarus<\/DisplayName>/);
  });

  // A player's layout: the Wax folder in the game with one mod, and its mods folder open in VS Code.
  const runtime = makeRuntime(path.join(base, 'Icarus', 'Binaries', 'Win64', 'ue4ss', 'Mods', 'Wax'));
  const modsDir = path.join(runtime, 'mods');
  put(modsDir, {
    'Hello/mod.lua': 'return { name = "Hello", version = "0.1.0" }\n',
    'Hello/init.lua': 'local window = ui.Window({ title = "Hello" })\nwindow:Button("Hi", function() ui.Notify("hi") end)\nreturn {}\n',
  });
  const slashed = (file) => file.split(path.sep).join('/');

  await t.test('activates by itself and points the language server at its own definitions', () => {
    const fake = fakeVscode.create({ folders: [modsDir], settings: { 'wax.runtimePath': runtime } });
    const loaded = fakeVscode.load(path.join(extension, 'extension.js'), fake.vscode);
    const context = fakeVscode.context(extension);
    const app = loaded.activate(context);
    app.game.stop();
    t.after(() => {
      loaded.deactivate();
      for (const item of context.subscriptions) item.dispose();
    });
    assert.equal(app.runtime, runtime);
    assert.equal(app.modsDir, modsDir);
    for (const file of [path.join(modsDir, 'Hello', '.luarc.json'), path.join(modsDir, '.luarc.json')]) {
      const settings = JSON.parse(read(file));
      assert.equal(settings['runtime.plugin'], slashed(path.join(extension, 'bundled', 'lsp', 'plugin.lua')));
      assert.equal(settings['workspace.library'][0], slashed(path.join(extension, 'bundled', 'types')));
    }
    assert.equal(fake.state.statusItems.find((item) => item.id === 'wax.status').text, '$(debug-disconnect) Wax: game not running');
  });

  await t.test('the language server accepts a mod through those files', { skip: !fs.existsSync(LANGUAGE_SERVER) && 'the Lua language server is not installed' }, () => {
    const check = () => spawnSync(LANGUAGE_SERVER, ['--check', path.join(modsDir, 'Hello'), '--checklevel=Warning',
      `--logpath=${path.join(base, 'log')}`, `--metapath=${path.join(base, 'meta')}`], { encoding: 'utf8' });
    const clean = check();
    assert.match(clean.stdout, /no problems found/, clean.stdout.slice(-3000));
    put(modsDir, { 'Hello/wrong.lua': 'ui.NoSuchThing()\n' });
    const caught = check();
    assert.match(caught.stdout, /1 problems found/, caught.stdout.slice(-3000));
    fs.rmSync(path.join(modsDir, 'Hello', 'wrong.lua'));

    // the packed plugin, reached by its full path, resolves a require of another mod
    const support = require(path.join(extension, 'lib', 'support.js'));
    put(modsDir, {
      'Base/init.lua': '---@class BaseExports\nlocal base = {}\n\nfunction base.greet() return "hi" end\n\nreturn base\n',
      'Hello/mod.lua': 'return { name = "Hello", version = "0.1.0", dependencies = { "Base" } }\n',
      'Hello/uses.lua': 'local base = require("@Base")\nprint(base.greet())\nprint(base.nothing())\n',
    });
    support.setUp({ folders: [modsDir], modsDir, extensionDir: extension });
    const across = check();
    assert.match(across.stdout, /1 problems found/, across.stdout.slice(-3000));
    assert.match(across.stdout, /nothing/);
    fs.rmSync(path.join(modsDir, 'Hello', 'uses.lua'));
    fs.rmSync(path.join(modsDir, 'Base'), { recursive: true });
  });

  await t.test('talks to the game with the bridge client it carries', { skip: !fs.existsSync(LUA) && 'standalone Lua is not installed' }, async (inner) => {
    const { Game, loadBridge } = require(path.join(extension, 'lib', 'game.js'));
    const bridge = await loadBridge(extension);
    assert.notEqual(bridge.ROOT, ROOT, 'this is the packed copy, not the workspace\'s');
    put(modsDir, { 'Hello/init.lua': 'print("hello is up")\nreturn {}\n', 'Hello/mod.lua': 'return { name = "Hello", version = "0.1.0" }\n' });
    writeIndex(runtime, modsDir);
    await startStandInGame(inner, runtime);
    const game = new Game({ runtime, bridge: async () => bridge, running: async () => true });
    const lines = [];
    game.on('log', (entries) => lines.push(...entries.map((entry) => entry.message)));
    assert.equal(await game.poll(), true);
    assert.deepEqual(game.mods.map((mod) => [mod.id, mod.status]), [['Hello', 'loaded']]);
    assert.ok(lines.includes('hello is up'));
    const result = await game.run({ source: 'return 1 + 1', chunkname: 'Hello/init.lua', modId: 'Hello', fresh: true });
    assert.deepEqual([result.ok, result.as, result.values], [true, 'Hello', ['2']]);
  });
});
