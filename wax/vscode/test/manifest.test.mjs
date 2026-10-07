// package.json, the snippets and the packing list agree with each other and with the code
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { require, read, EXTENSION, ROOT } from './helpers.mjs';

const manifest = require('../package.json');
const docs = require('../lib/docs.js');
const templates = require('../lib/templates.js');
const { contributes } = manifest;
const waxVersion = read(path.join(ROOT, 'wax', 'VERSION')).trim();
const walk = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
  (entry.isDirectory() ? walk(path.join(dir, entry.name)) : [path.join(dir, entry.name)]));
const source = ['extension.js', ...fs.readdirSync(path.join(EXTENSION, 'lib', 'features')).map((name) => `lib/features/${name}`)]
  .map((file) => read(path.join(EXTENSION, file))).join('\n');

test('the extension is who it says it is', () => {
  assert.equal(`${manifest.publisher}.${manifest.name}`, 'RobertCincotta.wax-icarus');
  assert.equal(manifest.displayName, 'Wax for Icarus');
  assert.match(manifest.version, /^\d+\.\d+\.\d+$/);
  assert.deepEqual(manifest.extensionDependencies, ['sumneko.lua']);
  assert.ok(fs.existsSync(path.join(EXTENSION, manifest.main)));
  assert.equal(manifest.dependencies, undefined, 'no runtime npm dependencies');
});

test('it does not run in a folder that is not trusted, or in one that is not on this PC', () => {
  // the extension sends Lua from the open folder into the game, so a folder from a stranger must not switch it on
  assert.deepEqual(Object.keys(manifest.capabilities).sort(), ['untrustedWorkspaces', 'virtualWorkspaces']);
  assert.equal(manifest.capabilities.untrustedWorkspaces.supported, false);
  assert.match(manifest.capabilities.untrustedWorkspaces.description, /Lua.*into the running game.*a folder you trust/);
  assert.equal(manifest.capabilities.virtualWorkspaces, false);
});

test('developer mode is switched on and off by two commands, and the README says what it allows', () => {
  const titles = Object.fromEntries(contributes.commands.map((command) => [command.command, command.title]));
  assert.equal(titles['wax.devModeOn'], 'Switch Developer Mode On');
  assert.equal(titles['wax.devModeOff'], 'Switch Developer Mode Off');
  assert.ok(source.includes('"Wax: Switch Developer Mode On"'), 'a message names the command');
  const readme = read(path.join(EXTENSION, 'README.md'));
  assert.match(readme, /## Developer mode/);
  assert.match(readme, /Any program on this PC can run Lua in the game, and Lua in the game can do what a program can\./);
  assert.match(readme, /Wax does not update itself/);
  assert.match(readme, /`dev\.txt` in the Wax folder, beside `Scripts`/);
  assert.match(readme, /only runs in a folder you trust/);
  for (const command of ['Wax: Switch Developer Mode On', 'Wax: Switch Developer Mode Off']) assert.ok(readme.includes(`**${command}**`), command);
});

test('every menu entry is a declared command, and its buttons have icons', () => {
  const commands = new Map(contributes.commands.map((command) => [command.command, command]));
  for (const [menu, entries] of Object.entries(contributes.menus)) {
    for (const entry of entries) {
      assert.ok(commands.has(entry.command), `${menu}: ${entry.command}`);
      const isButton = menu === 'editor/title/run' || /^(navigation|inline)/.test(entry.group ?? '');
      if (isButton && menu !== 'commandPalette') assert.ok(commands.get(entry.command).icon, `${entry.command} shows as a button and needs an icon`);
    }
  }
});

test('the buttons in the editor title only show for Lua files', () => {
  for (const menu of ['editor/title', 'editor/title/run', 'editor/context']) {
    for (const entry of contributes.menus[menu]) assert.match(entry.when, /(resource|editor)LangId == lua/, `${menu}: ${entry.command}`);
  }
  const titles = Object.fromEntries(contributes.commands.map((command) => [command.command, command]));
  assert.equal(titles['wax.runFile'].icon, '$(play)');
  assert.equal(titles['wax.reloadMod'].icon, '$(refresh)');
  assert.deepEqual(contributes.menus['editor/title/run'].map((entry) => entry.command), ['wax.runFile', 'wax.runSelection']);
  assert.deepEqual(contributes.menus['editor/title'].map((entry) => entry.command), ['wax.runFile', 'wax.reloadMod', 'wax.stopScripts']);
  assert.deepEqual(contributes.keybindings.map((entry) => `${entry.key} ${entry.command}`), ['ctrl+alt+enter wax.runSelection', 'ctrl+alt+enter wax.runFile']);
});

test('the context keys the menus wait for are set by the code, and the view exists', () => {
  const keys = new Set();
  const whens = [...Object.values(contributes.menus).flat(), ...contributes.viewsWelcome].map((entry) => entry.when ?? '');
  for (const when of whens) for (const match of when.matchAll(/\bwax\.[A-Za-z]+\b/g)) keys.add(match[0]);
  keys.delete('wax.mods');
  assert.deepEqual([...keys].sort(), ['wax.connected', 'wax.editorInMod', 'wax.hasRuntime']);
  for (const key of keys) assert.ok(source.includes(`'setContext', '${key}'`), key);

  const container = contributes.viewsContainers.activitybar[0];
  assert.equal(container.title, 'Wax');
  assert.ok(fs.existsSync(path.join(EXTENSION, container.icon)));
  assert.deepEqual(contributes.views[container.id].map((view) => view.id), ['wax.mods']);
  assert.ok(source.includes("createTreeView('wax.mods'"));
  const inline = contributes.menus['view/item/context'].filter((entry) => entry.group.startsWith('inline')).map((entry) => entry.command);
  assert.deepEqual(inline.sort(), ['wax.disableMod', 'wax.enableMod', 'wax.newScript', 'wax.openMod', 'wax.reloadMod']);
  const title = contributes.menus['view/title'].filter((entry) => entry.group.startsWith('navigation')).map((entry) => entry.command);
  assert.deepEqual(title, ['wax.newMod', 'wax.refreshMods']);
});

test('the settings are the three the code reads', () => {
  const settings = contributes.configuration.properties;
  assert.deepEqual(Object.keys(settings).sort(), ['wax.docsUrl', 'wax.gamePath', 'wax.runtimePath']);
  assert.equal(settings['wax.docsUrl'].default, docs.DOCS);
  for (const name of Object.keys(settings)) assert.ok(source.includes(`get('${name.slice(4)}'`), name);
  // a path on this PC is no use on another one, so the two paths are not carried along by Settings Sync
  for (const name of ['wax.gamePath', 'wax.runtimePath']) {
    assert.equal(settings[name].default, '');
    assert.equal(settings[name].scope, 'machine-overridable');
  }
  assert.ok(source.includes("update('gamePath'"), 'the folder the user chooses is saved');
});

test('the Marketplace page says what the extension is, where Wax comes from and where the docs are', () => {
  assert.equal(manifest.homepage, docs.DOCS);
  assert.equal(docs.DOCS, 'https://wax-icarus.duckdns.org/');
  assert.equal(docs.DOWNLOAD, 'https://wax-icarus.duckdns.org/docs/install/');
  const readme = read(path.join(EXTENSION, 'README.md'));
  for (const needed of [docs.DOCS, docs.DOWNLOAD, 'RobertCincotta.wax-icarus', 'Install Wax.cmd', 'Binaries\\Win64', `Wax-${waxVersion}.zip`]) {
    assert.ok(readme.includes(needed), needed);
  }
  // without a repository in package.json a relative link or picture would be broken on the Marketplace
  for (const target of readme.matchAll(/\]\(([^)]+)\)/g)) assert.match(target[1], /^https:\/\//, target[0]);
  for (const place of ['bugs', 'repository']) {
    const value = manifest[place] && (manifest[place].url ?? manifest[place]);
    if (value) assert.ok(value.startsWith(docs.DOCS) || value.startsWith(docs.DOWNLOAD), place);
  }
  assert.ok(manifest.categories.length > 0 && manifest.keywords.length >= 5 && manifest.keywords.length <= 30);
  for (const keyword of ['icarus', 'wax', 'lua']) assert.ok(manifest.keywords.includes(keyword), keyword);
});

test('the commands are named the way the user is told to find them', () => {
  const titles = Object.fromEntries(contributes.commands.map((command) => [command.command, command.title]));
  assert.equal(titles['wax.chooseGameFolder'], 'Choose the ICARUS Folder');
  assert.equal(titles['wax.newMod'], 'New Mod');
  assert.equal(titles['wax.openDocs'], 'Open Documentation');
  // a command a message or the README names by its full title exists under that title
  const named = new Set(contributes.commands.map((command) => `Wax: ${command.title}`));
  const texts = [read(path.join(EXTENSION, 'README.md')), source, ...Object.values(contributes.configuration.properties).map((setting) => setting.markdownDescription ?? setting.description)];
  for (const text of texts) {
    for (const mention of text.matchAll(/(?:"|\*\*)(Wax: [^"*\n]+)(?:"|\*\*)/g)) assert.ok(named.has(mention[1]), mention[0]);
  }
  const welcome = contributes.viewsWelcome.map((entry) => entry.contents).join('\n');
  for (const link of welcome.matchAll(/\(command:([\w.]+)\)/g)) assert.ok(Object.hasOwn(titles, link[1]), link[0]);
  assert.match(welcome, /\[Choose the ICARUS Folder\]\(command:wax\.chooseGameFolder\)/);
  assert.match(welcome, /\[Get Wax\]\(command:wax\.getWax\)/);
});

test('the icon is a 128 by 128 PNG', () => {
  const png = fs.readFileSync(path.join(EXTENSION, manifest.icon));
  assert.equal(png.subarray(1, 4).toString('latin1'), 'PNG');
  assert.deepEqual([png.readUInt32BE(16), png.readUInt32BE(20)], [128, 128]);
});

test('the snippets are for Lua and cover the everyday things', () => {
  assert.deepEqual(contributes.snippets, [{ language: 'lua', path: './snippets/wax.json' }]);
  const snippets = Object.values(JSON.parse(read(path.join(EXTENSION, 'snippets', 'wax.json'))));
  const prefixes = snippets.map((snippet) => snippet.prefix);
  for (const wanted of ['wax-window', 'wax-toggle', 'wax-loop', 'wax-notify']) assert.ok(prefixes.includes(wanted), wanted);
  assert.equal(new Set(prefixes).size, prefixes.length);
  for (const snippet of snippets) {
    assert.match(snippet.prefix, /^wax-[a-z]+$/);
    assert.ok(Array.isArray(snippet.body) && snippet.body.length > 0 && snippet.description, snippet.prefix);
  }
});

test('the modules the tests cover do not need VS Code, and nothing reaches it except through extension.js', () => {
  for (const file of walk(path.join(EXTENSION, 'lib')).filter((name) => name.endsWith('.js'))) {
    assert.ok(!/require\(\s*['"]vscode['"]\s*\)/.test(read(file)), path.relative(EXTENSION, file));
  }
  assert.match(read(path.join(EXTENSION, 'extension.js')), /require\('vscode'\)/);
});

test('the package leaves out the tests and keeps what the extension loads', () => {
  const ignored = read(path.join(EXTENSION, '.vscodeignore')).split(/\r?\n/).filter(Boolean);
  assert.ok(ignored.includes('test/**'));
  for (const kept of ['lib', 'lua', 'bundled', 'snippets', 'media/wax.svg', 'extension.js', 'icon.png', 'README.md']) {
    assert.ok(!ignored.some((pattern) => pattern.startsWith(kept)), kept);
  }
});

test('what the build copies into the extension is there to copy', () => {
  for (const file of ['wax/cli/bridge.mjs', 'wax/lsp/plugin.lua', 'wax/types/ui.lua', 'wax/types/lua_basic.lua', 'wax/types/icarus/classes.txt']) {
    assert.ok(fs.existsSync(path.join(ROOT, file)), file);
  }
  const build = read(path.join(ROOT, 'scripts', 'Build-WaxExtension.ps1'));
  for (const piece of ["'wax\\types')", 'wax\\lsp\\plugin.lua', 'wax\\cli\\bridge.mjs']) assert.ok(build.includes(piece), piece);
});
