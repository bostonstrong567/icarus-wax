// The whole extension, activated against a stand-in for VS Code and a stand-in for the game's replies
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { require, scratch, put, read, makeRuntime, makeGame, waxIn, EXTENSION } from './helpers.mjs';

const fakeVscode = require('./fake-vscode.cjs');
const manifest = require('../package.json');
const DOCS = 'https://wax-icarus.duckdns.org/';
const DOWNLOAD = 'https://wax-icarus.duckdns.org/docs/install/';
const CHOOSE = 'Choose the ICARUS folder';
const GET = 'Get Wax';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const answer = (value) => ({ ok: true, values: [value], output: {} });

// A workspace laid out like this one: wax/runtime and luamods, with one mod in it.
function makeWorkspace(t) {
  const root = scratch(t);
  put(root, {
    'wax/runtime/Scripts/main.lua': '-- stage 0\n',
    'luamods/Hello/mod.lua': 'return {\n    name = "Hello",\n    version = "0.1.0",\n}\n',
    'luamods/Hello/init.lua': 'print("hello")\nreturn {}\n',
  });
  return root;
}

// Activates the extension in a workspace; the game is whatever `replies` (a list the test fills) says.
// steam: the copies of the game Steam has, as [{ game, runtime }]. stored: what an earlier session remembered.
// reply: what the user answers from the first moment on.
function start(t, root, settings = {}, { steam = [], stored = {}, reply } = {}) {
  const fake = fakeVscode.create({ folders: [root], settings });
  if (reply) fake.state.reply = reply;
  const extension = fakeVscode.load(path.join(EXTENSION, 'extension.js'), fake.vscode);
  // this PC's own Steam and game are never looked at
  require('../lib/paths.js').findSteamGames = () => steam;
  const context = fakeVscode.context(EXTENSION, stored);
  const app = extension.activate(context);
  app.game.stop();
  const replies = [];
  const sent = [];
  app.game.running = async () => true;
  app.game.loadBridge = async () => ({
    evalLua: async (code) => {
      sent.push(code);
      return replies.shift() ?? { ok: false, error: 'timeout: the game did not pick up the request (game thread not ticking?)' };
    },
  });
  t.after(() => {
    extension.deactivate();
    for (const item of context.subscriptions) item.dispose();
  });
  return { ...fake, app, context, replies, sent, steam, root, mods: path.join(root, 'luamods') };
}

const output = (session) => session.state.channels.get('Wax').lines;
const status = (session) => session.state.statusItems.find((item) => item.id === 'wax.status');
const tree = (session) => {
  const { provider } = session.state.views.get('wax.mods');
  return provider.getChildren().map((mod) => ({ mod, item: provider.getTreeItem(mod) }));
};
const diagnostics = (session, name) => [...session.state.diagnostics.get(name).entries()];

test('every command the manifest offers is registered, and nothing else', (t) => {
  const session = start(t, makeWorkspace(t));
  const declared = manifest.contributes.commands.map((command) => command.command).sort();
  assert.deepEqual([...session.state.commands.keys()].sort(), declared);
  for (const command of manifest.contributes.commands) assert.equal(command.category, 'Wax', command.command);
});

test('on activation: the runtime is found, the mods are listed from disk, editor support is written', (t) => {
  const session = start(t, makeWorkspace(t));
  assert.equal(session.app.runtime, path.join(session.root, 'wax', 'runtime'));
  assert.equal(session.app.modsDir, session.mods);
  assert.equal(session.state.contexts['wax.hasRuntime'], true);
  assert.deepEqual([status(session).text, status(session).visible, status(session).command], ['$(debug-disconnect) Wax: game not running', true, 'wax.showLog']);
  assert.equal(session.state.channels.get('Wax').languageId, 'log');

  const [hello] = tree(session);
  assert.deepEqual([hello.item.label, hello.item.description, hello.item.contextValue, hello.item.iconPath.id], ['Hello', '0.1.0  on disk', 'mod.disk', 'package']);
  assert.match(session.state.views.get('wax.mods').message, /not running/);

  const luarc = JSON.parse(read(path.join(session.mods, 'Hello', '.luarc.json')));
  assert.equal(luarc['runtime.version'], 'Lua 5.4');
  for (const library of luarc['workspace.library']) assert.ok(fs.existsSync(library), `${library} exists`);
  assert.ok(fs.existsSync(luarc['runtime.plugin']));
  assert.equal(session.state.watchers.at(-1).pattern.base, session.mods);
});

// Answers New Mod's three questions with `answers` (undefined is Escape) and keeps what was asked.
function answerNewMod(session, answers) {
  const asked = [];
  session.state.reply = (kind, detail) => {
    if (kind !== 'input' && kind !== 'pick') return undefined;
    asked.push({ kind, ...(kind === 'pick' ? { items: detail.items, ...detail.options } : detail) });
    const answer = answers[asked.length - 1];
    return kind === 'pick' && answer !== undefined ? detail.items.find((item) => item.label === answer) : answer;
  };
  return asked;
}

test('New Mod asks for a name, a description and a starting point, writes the files, opens init.lua and sets the mod up', async (t) => {
  const session = start(t, makeWorkspace(t));
  const asked = answerNewMod(session, ['My First Mod', 'Shows the map I am on.', 'Overlay']);
  await session.user.run('wax.newMod');
  assert.deepEqual(asked.map((question) => question.kind), ['input', 'input', 'pick']);
  assert.deepEqual(asked.map((question) => question.title), ['New Mod (1 of 3): name', 'New Mod (2 of 3): description', 'New Mod (3 of 3): starting point']);
  assert.equal(asked[0].validateInput('Hello'), 'A mod named "Hello" already exists.');
  assert.equal(asked[0].validateInput('Fine Name'), null);
  assert.equal(asked[1].validateInput, undefined, 'any description will do, also none');
  assert.deepEqual(asked[2].items.map((item) => item.label), ['Empty', 'Window with a button', 'Overlay']);
  for (const item of asked[2].items) assert.ok(item.detail, item.label);

  const dir = path.join(session.mods, 'MyFirstMod');
  assert.equal(read(path.join(dir, 'mod.lua')), 'return {\n    name = "My First Mod",\n    description = "Shows the map I am on.",\n    version = "0.1.0",\n}\n');
  assert.match(read(path.join(dir, 'init.lua')), /ui\.Overlay\(\{ title = "My First Mod"/);
  assert.deepEqual(session.state.shown, [path.join(dir, 'init.lua')]);
  assert.ok(fs.existsSync(path.join(dir, '.luarc.json')));
  assert.deepEqual(tree(session).map(({ mod }) => mod.id), ['Hello', 'MyFirstMod']);
  assert.match(tree(session)[1].item.tooltip, /Shows the map I am on\./);
  assert.match(session.state.messages.at(-1).text, /MyFirstMod was created in .*\. The game lists it switched off, as it does every mod it has not seen before\. Switch it on in the Mods view here/);
  assert.equal(session.state.contexts['wax.editorInMod'], true);
});

test('New Mod with no description and each of the other starting points', async (t) => {
  const session = start(t, makeWorkspace(t));
  answerNewMod(session, ['Quiet', '', 'Empty']);
  await session.user.run('wax.newMod');
  assert.equal(read(path.join(session.mods, 'Quiet', 'mod.lua')), 'return {\n    name = "Quiet",\n    version = "0.1.0",\n}\n');
  assert.match(read(path.join(session.mods, 'Quiet', 'init.lua')), /^print\("Quiet loaded"\)$/m);
  answerNewMod(session, ['Clicky', '', 'Window with a button']);
  await session.user.run('wax.newMod');
  assert.match(read(path.join(session.mods, 'Clicky', 'init.lua')), /window:Button\("Say hello"/);
  assert.equal(session.state.shown.at(-1), path.join(session.mods, 'Clicky', 'init.lua'));
});

test('New Mod writes nothing when any of its questions is left with Escape', async (t) => {
  const session = start(t, makeWorkspace(t));
  for (const answers of [[undefined], ['Half Made', undefined], ['Half Made', 'A description.', undefined]]) {
    const asked = answerNewMod(session, answers);
    await session.user.run('wax.newMod');
    assert.equal(asked.length, answers.length);
  }
  assert.deepEqual(fs.readdirSync(session.mods).sort(), ['Hello']);
  assert.deepEqual(session.state.shown, []);

  // a name that is taken stops it, and the mod that is there is left as it was
  const before = read(path.join(session.mods, 'Hello', 'init.lua'));
  answerNewMod(session, ['hello', '', 'Empty']);
  await session.user.run('wax.newMod');
  assert.equal(session.state.messages.at(-1).text, 'Wax: A mod named "hello" already exists.');
  assert.equal(read(path.join(session.mods, 'Hello', 'init.lua')), before);
});

test('New Script adds a module to the mod of the open file', async (t) => {
  const session = start(t, makeWorkspace(t));
  await session.user.open(path.join(session.mods, 'Hello', 'init.lua'));
  let asked;
  session.state.reply = (kind, detail) => {
    asked = detail;
    return 'gui.panel';
  };
  await session.user.run('wax.newScript');
  assert.equal(asked.title, 'New Script in Hello');
  assert.match(asked.validateInput('init'), /the mod itself/);
  const file = path.join(session.mods, 'Hello', 'gui', 'panel.lua');
  assert.match(read(file), /local panel = \{\}/);
  assert.equal(session.state.shown.at(-1), file);
  assert.match(session.state.statusMessages.at(-1), /require\(mod\.gui\.panel\)/);
});

test('inside require("...") the mod\'s modules and the other mods are offered', async (t) => {
  const session = start(t, makeWorkspace(t));
  put(session.mods, { 'Hello/util.lua': 'return {}\n', 'Other/init.lua': 'return {}\n' });
  session.app.scanned = null;
  const document = await session.user.open(path.join(session.mods, 'Hello', 'init.lua'), 'local util = require("ut")\n');
  const [{ provider, triggers, selector }] = session.state.completions;
  assert.deepEqual(selector, { language: 'lua', scheme: 'file' });
  assert.deepEqual(triggers, ['"', "'", '@', '.', '/']);
  const items = provider.provideCompletionItems(document, new session.vscode.Position(0, 24));
  assert.deepEqual(items.map((item) => item.label), ['util', '@Other']);
  assert.deepEqual(items.map((item) => item.documentation.value), [
    `Wax docs: [More than one file](${DOCS}docs/mods/#more-than-one-file)`,
    `Wax docs: [Using another mod](${DOCS}docs/mods/#using-another-mod)`,
  ]);
  assert.deepEqual([items[0].range.inserting.start.character, items[0].range.inserting.end.character, items[0].range.replacing.end.character], [22, 24, 24]);
  assert.equal(provider.provideCompletionItems(document, new session.vscode.Position(0, 5)), undefined);
  // a Lua file that belongs to no mod gets nothing
  put(session.root, { 'loose.lua': 'require("' });
  const loose = await session.user.open(path.join(session.root, 'loose.lua'));
  assert.equal(provider.provideCompletionItems(loose, new session.vscode.Position(0, 9)), undefined);
});

test('a require the loader would refuse is marked, and the quick fix adds the dependency', async (t) => {
  const session = start(t, makeWorkspace(t));
  put(session.mods, { 'Other/init.lua': 'return {}\n' });
  session.app.scanned = null;
  const file = path.join(session.mods, 'Hello', 'init.lua');
  const document = await session.user.open(file, 'local other = require("@Other")\nlocal typo = require("nope")\n');
  await sleep(350);
  const [[uri, found]] = diagnostics(session, 'wax-requires');
  assert.equal(uri, document.uri.toString());
  assert.deepEqual(found.map((d) => [d.code.value, d.source, d.severity, document.getText(d.range)]), [['undeclared', 'Wax', 0, '@Other'], ['missing-module', 'Wax', 0, 'nope']]);
  // each one links to the page that explains it
  assert.deepEqual(found.map((d) => d.code.target.toString()), [`${DOCS}docs/mods/#using-another-mod`, `${DOCS}docs/mods/#more-than-one-file`]);

  const [{ provider }] = session.state.codeActions;
  const actions = provider.provideCodeActions(document, found[0].range, { diagnostics: found });
  assert.deepEqual(actions.map((action) => action.title), ['Add "Other" to dependencies in mod.lua']);
  await session.user.run(actions[0].command.command, ...actions[0].command.arguments);
  assert.equal(read(path.join(session.mods, 'Hello', 'mod.lua')), 'return {\n    name = "Hello",\n    version = "0.1.0",\n    dependencies = { "Other" },\n}\n');
  await sleep(350);
  assert.deepEqual(diagnostics(session, 'wax-requires')[0][1].map((d) => d.code.value), ['missing-module']);
  // the mod now sees the mod it depends on
  assert.equal(JSON.parse(read(path.join(session.mods, 'Hello', '.luarc.json')))['workspace.library'].at(-1), '../Other');
});

const LIST = [
  { id: 'Hello', name: 'Hello', version: '0.1.0', status: 'loaded', enabled: true, generation: 3, loadMs: 4.25 },
  { id: 'Broken', name: 'Broken', status: 'failed', enabled: true, generation: 0, error: 'Broken/init.lua:2: attempt to call a nil value' },
  { id: 'Off', name: 'Switched Off', version: '2.0', status: 'disabled', enabled: false, generation: 1 },
];

function connect(session) {
  put(session.mods, { 'Broken/init.lua': 'local x\nx()\n', 'Off/init.lua': 'return {}\n' });
  session.app.scanned = null;
  session.replies.push(answer({
    core: 'table: 0x01', newest: 3, mods: LIST,
    entries: [
      { id: 1, time: 1791269016, level: 'info', channel: 'wax.mods', message: 'Hello 0.1.0 loaded in 4.3 ms', count: 1, again: false },
      { id: 2, time: 1791269017, level: 'error', channel: 'Broken', message: 'loading Broken: Broken/init.lua:2: attempt to call a nil value\nstack traceback:\n\t[C]: in ?', count: 1, again: false },
      { id: 3, time: 1791269018, level: 'warn', channel: 'Hello', message: 'careful', count: 1, again: false },
    ],
  }));
  return session.app.game.poll();
}

test('connected: the status bar counts the mods, the log follows, errors become problems, the view shows each mod', async (t) => {
  const session = start(t, makeWorkspace(t));
  assert.equal(await connect(session), true);
  assert.equal(session.state.contexts['wax.connected'], true);
  assert.equal(status(session).text, '$(plug) Wax: 3 mods, 1 failed');
  assert.equal(status(session).backgroundColor.id, 'statusBarItem.warningBackground');

  const lines = output(session);
  assert.match(lines[0], /\[info\] \[editor\] connected to the game$/);
  assert.match(lines[1], /^\d\d:\d\d:\d\d \[info\] \[wax\.mods\] Hello 0\.1\.0 loaded in 4\.3 ms$/);
  assert.match(lines[2], /\[error\] \[Broken\] loading Broken: Broken\/init\.lua:2: attempt to call a nil value\n    stack traceback:\n    \[C\]: in \?$/);
  assert.match(lines[3], /\[warn\] \[Hello\] careful$/);

  const [[uri, found]] = diagnostics(session, 'wax-game');
  assert.equal(uri, session.vscode.Uri.file(path.join(session.mods, 'Broken', 'init.lua')).toString());
  assert.deepEqual(found.map((d) => [d.message, d.range.start.line, d.severity, d.source]), [['attempt to call a nil value', 1, 0, 'Wax (did not load)']]);

  assert.deepEqual(tree(session).map(({ item }) => [item.label, item.description, item.contextValue, item.iconPath.id]), [
    ['Hello', '0.1.0  loaded', 'mod.on', 'pass'],
    ['Broken', 'failed', 'mod.on', 'error'],
    ['Switched Off', '2.0  switched off', 'mod.off', 'circle-slash'],
  ]);
  assert.equal(session.state.views.get('wax.mods').message, undefined);
  assert.match(tree(session)[1].item.tooltip, /attempt to call a nil value/);

  // the mod is fixed and loads: its problem goes
  session.replies.push(answer({
    core: 'table: 0x01', newest: 4, mods: [LIST[0], { ...LIST[1], status: 'loaded', error: undefined, generation: 1 }, LIST[2]],
    entries: [{ id: 4, time: 1791269020, level: 'info', channel: 'wax.mods', message: 'Broken  loaded in 0.4 ms', count: 1, again: false }],
  }));
  await session.app.game.poll();
  assert.deepEqual(diagnostics(session, 'wax-game'), []);
  assert.equal(status(session).text, '$(plug) Wax: 3 mods');
  assert.equal(status(session).backgroundColor, undefined);

  // the game goes away
  session.app.game.running = async () => false;
  session.app.game.active = true;
  await session.app.game.tick();
  session.app.game.stop();
  assert.equal(status(session).text, '$(debug-disconnect) Wax: game not running');
  assert.equal(session.state.contexts['wax.connected'], false);
  assert.match(output(session).at(-1), /the game is gone$/);
  assert.equal(tree(session)[0].item.contextValue, 'mod.disk');
});

test('New Mod while the game runs: the game holds the new mod, and the message offers to switch it on', async (t) => {
  const session = start(t, makeWorkspace(t));
  await connect(session);
  answerNewMod(session, ['Late One', '', 'Empty']);
  const held = { id: 'LateOne', name: 'Late One', version: '0.1.0', status: 'disabled', enabled: false, fresh: true, generation: 0 };
  // the refresh New Mod asks for, the look after it, then the switch and the look after that
  session.replies.push(answer(true), answer({ core: 'table: 0x01', newest: 3, entries: {}, mods: [...LIST, held] }),
    answer(true), answer({ core: 'table: 0x01', newest: 3, entries: {}, mods: [...LIST, { ...held, status: 'loaded', enabled: true, fresh: undefined }] }));
  const asked = session.state.reply;
  session.state.reply = (kind, detail) => (kind === 'message' && detail.items.includes('Enable in Game') ? 'Enable in Game' : asked(kind, detail));
  await session.user.run('wax.newMod');
  const said = session.state.messages.at(-1);
  assert.equal(said.text, 'Wax: LateOne was created. The game lists a mod it has not seen before switched off.');
  assert.deepEqual(said.items, ['Enable in Game']);
  assert.ok(session.sent.at(-2).endsWith('end)("enable", "LateOne")'));
  assert.equal(tree(session).at(-1).item.description, '0.1.0  loaded');
  // before it was switched on, the view said why it was off
  const { provider } = session.state.views.get('wax.mods');
  assert.equal(provider.getTreeItem({ ...held, inGame: true }).description, '0.1.0  new, switched off until you enable it');
});

// What the game answers to Lua while developer mode is off.
const refusal = () => ({ ok: false, code: 'dev-off', output: {}, error: 'Developer mode is off, so this was not run. Wax only runs Lua sent from outside the game while a file named dev.txt is in its folder.' });
const ON = 'Switch Developer Mode On';

// A player's layout: the Wax folder in the game, found through a setting, with its mods folder open.
function makeInstalled(t) {
  const game = makeGame(path.join(scratch(t), 'steamapps', 'common', 'Icarus'));
  const runtime = makeRuntime(waxIn(game));
  put(runtime, { 'mods/Hello/init.lua': 'return {}\n' });
  return { game, runtime, session: start(t, path.join(runtime, 'mods'), { 'wax.gamePath': game }) };
}

test('a game with developer mode off: the status bar and the view say so, and a command that sends Lua offers the switch', async (t) => {
  const { session, runtime } = makeInstalled(t);
  session.replies.push(refusal());
  assert.equal(await session.app.game.poll(), true);
  assert.equal(session.app.game.state, 'devoff');
  assert.deepEqual([status(session).text, status(session).command, status(session).visible], ['$(lock) Wax: developer mode is off', 'wax.devModeOn', true]);
  assert.match(status(session).tooltip, /only in developer mode\. Click to switch it on\.$/);
  assert.match(output(session).at(-1), /\[info\] \[editor\] the game is running with developer mode off.*"Wax: Switch Developer Mode On" changes that\.$/);
  assert.match(session.state.views.get('wax.mods').message, /^Developer mode is off, so the game does not tell the editor about its mods\./);
  assert.deepEqual(tree(session).map(({ item }) => [item.label, item.contextValue]), [['Hello', 'mod.disk']]);
  assert.equal(session.state.contexts['wax.connected'], false);

  // each thing that sends Lua says what the mode is, with the button, and shows no error
  await session.user.open(path.join(runtime, 'mods', 'Hello', 'init.lua'));
  for (const command of ['wax.runFile', 'wax.reloadMod', 'wax.stopScripts']) {
    const before = session.state.messages.length;
    session.replies.push(refusal());
    await session.user.run(command);
    assert.equal(session.state.messages.length, before + 1, command);
    assert.deepEqual(session.state.messages.at(-1), { level: 'warning', items: [ON],
      text: 'Wax: developer mode is off, so the game did not run this. The game runs Lua sent from the editor only while developer mode is on.' }, command);
  }
  session.user.select(0, 0, 0, 9);
  session.replies.push(refusal());
  await session.user.run('wax.runSelection');
  assert.deepEqual(session.state.messages.at(-1).items, [ON]);
  session.replies.push(refusal());
  await session.user.run('wax.enableMod', { id: 'Hello' });
  assert.deepEqual(session.state.messages.at(-1).items, [ON]);
  assert.ok(!session.state.messages.some((message) => message.level === 'error'));

  // back to the log once the game runs Lua again
  session.app.game.loadBridge = async () => ({ evalLua: async () => answer({ core: 'table: 0x01', newest: 1, entries: {}, mods: {} }), ping: async () => ({ dev: true, core: true }) });
  await session.app.game.poll();
  assert.deepEqual([status(session).text, status(session).command], ['$(plug) Wax: 0 mods', 'wax.showLog']);
});

test('Switch Developer Mode On asks one question that says what it allows, and writes dev.txt only on a yes', async (t) => {
  const { session, runtime } = makeInstalled(t);
  const file = path.join(runtime, 'dev.txt');
  await session.user.run('wax.devModeOn');
  const asked = session.state.messages.at(-1);
  assert.equal(asked.level, 'warning');
  assert.equal(asked.text, `Switch developer mode on for the Wax at ${runtime}?`);
  assert.deepEqual(asked.items, [ON]);
  assert.equal(asked.options.modal, true, 'it cannot be missed, and closing it is a no');
  assert.match(asked.options.detail, /^While it is on, any program on this PC can run Lua in the game, and Lua in the game can do what a program can\./);
  assert.match(asked.options.detail, /Wax also stops updating itself while it is on\./);
  assert.equal(fs.existsSync(file), false, 'no answer, no file');

  session.state.reply = (kind, detail) => (kind === 'message' && detail.options ? ON : undefined);
  await session.user.run('wax.devModeOn');
  assert.match(read(file), /^Developer mode is on for this copy of Wax\./);
  assert.match(read(file), /Delete this file to switch developer mode off\./);
  assert.deepEqual([session.state.messages.at(-1).level, session.state.messages.at(-1).text],
    ['info', 'Wax: developer mode is on. A game that is running takes it up at once.']);
  session.app.game.stop();

  // asked again, it says so and asks nothing
  const count = session.state.messages.length;
  await session.user.run('wax.devModeOn');
  session.app.game.stop();
  assert.equal(session.state.messages.length, count + 1);
  assert.equal(session.state.messages.at(-1).text, `Wax: developer mode is already on for the Wax at ${runtime}.`);
  assert.equal(session.state.messages.at(-1).options, undefined);

  await session.user.run('wax.devModeOff');
  session.app.game.stop();
  assert.equal(fs.existsSync(file), false);
  assert.match(session.state.messages.at(-1).text, /^Wax: developer mode is off\. The game no longer runs Lua sent from outside it\./);
  await session.user.run('wax.devModeOff');
  assert.equal(session.state.messages.at(-1).text, `Wax: developer mode is already off for the Wax at ${runtime}.`);
});

test('the button on the refusal leads to the same question', async (t) => {
  const { session, runtime } = makeInstalled(t);
  session.state.reply = (kind) => (kind === 'message' ? ON : undefined);
  await session.user.open(path.join(runtime, 'mods', 'Hello', 'init.lua'));
  session.replies.push(refusal());
  await session.user.run('wax.runFile');
  await sleep(20);
  session.app.game.stop();
  const texts = session.state.messages.slice(-3).map((message) => message.text);
  assert.match(texts[0], /^Wax: developer mode is off, so the game did not run this\./);
  assert.equal(texts[1], `Switch developer mode on for the Wax at ${runtime}?`);
  assert.equal(texts[2], 'Wax: developer mode is on. A game that is running takes it up at once.');
  assert.ok(fs.existsSync(path.join(runtime, 'dev.txt')));
});

test('in the Wax development workspace developer mode is not switched off: its dev.txt also stops Wax updating its own files', async (t) => {
  const root = makeWorkspace(t);
  put(root, { 'wax/runtime/dev.txt': 'This copy of Wax is a development workspace.\n' });
  const session = start(t, root);
  await session.user.run('wax.devModeOff');
  assert.equal(read(path.join(root, 'wax', 'runtime', 'dev.txt')), 'This copy of Wax is a development workspace.\n');
  assert.match(session.state.messages.at(-1).text, /is the development copy of Wax in the open folder\. Its dev\.txt also keeps Wax from updating its own files there, so it stays\.$/);
  await session.user.run('wax.devModeOn');
  session.app.game.stop();
  assert.match(session.state.messages.at(-1).text, /^Wax: developer mode is already on/);
});

test('without the game\'s Wax folder the two commands ask for the game, and write nothing', async (t) => {
  const root = path.join(scratch(t), 'project');
  put(root, { 'notes.lua': 'print("not a mod")\n' });
  const session = start(t, root);
  const before = session.state.messages.length;
  await session.user.run('wax.devModeOn');
  await session.user.run('wax.devModeOff');
  assert.equal(session.state.messages.length, before + 2);
  assert.deepEqual(session.state.messages.at(-1).items, ['Choose the ICARUS folder', 'Get Wax']);
});

test('Run File sends the editor\'s text and shows what came back', async (t) => {
  const session = start(t, makeWorkspace(t));
  await connect(session);
  const document = await session.user.open(path.join(session.mods, 'Hello', 'init.lua'), 'return 1 + 1\n');
  session.replies.push(answer({ ok: true, values: ['2'], as: 'Hello', kept: 0 }), answer({ core: 'table: 0x01', newest: 4, entries: {}, mods: LIST }));
  await session.user.run('wax.runFile', document.uri);
  assert.ok(session.sent.at(-2).endsWith('end)("return 1 + 1\\n", "Hello/init.lua", "Hello", true, false)'));
  assert.deepEqual(output(session).slice(-2).map((line) => line.replace(/^\d\d:\d\d:\d\d /, '')), ['[run] the file of Hello/init.lua, as Hello', '    = 2']);
  assert.ok(session.state.channels.get('Wax').revealed > 0);

  // an error is shown, and marked on the line it names
  session.user.type(document, 'local a = 1\nlocal b = nil\nreturn b.c\n');
  session.replies.push(answer({ ok: false, as: 'Hello', kept: 0, error: "Hello/init.lua:3: attempt to index a nil value (local 'b')\nstack traceback:\n\tHello/init.lua:3: in main chunk\n\t[C]: in function 'xpcall'\n\teval:70: in function <eval:69>" }));
  await session.user.run('wax.runFile');
  assert.equal(session.state.messages.at(-1).text, "Wax: Hello/init.lua:3: attempt to index a nil value (local 'b')");
  const [[uri, found]] = diagnostics(session, 'wax-run');
  assert.equal(uri, document.uri.toString());
  assert.deepEqual([found[0].message, found[0].range.start.line, found[0].source], ["attempt to index a nil value (local 'b')", 2, 'Wax (run)']);
  assert.ok(!output(session).some((line) => line.includes('eval:70')), 'the frames of the bridge are left out');

  // a clean run clears the mark
  session.replies.push(answer({ ok: true, values: {}, as: 'Hello', kept: 2 }));
  await session.user.run('wax.runFile');
  assert.deepEqual(diagnostics(session, 'wax-run'), []);
  assert.ok(output(session).some((line) => line.includes('2 things it set up stay')));
});

test('Run Selection sends the selection, or the line the cursor is on, keeping line numbers', async (t) => {
  const session = start(t, makeWorkspace(t));
  await connect(session);
  put(session.root, { 'scratch.lua': 'local a = 1\nprint(a)\ngame.MapName\n' });
  await session.user.open(path.join(session.root, 'scratch.lua'));
  session.user.select(2, 0, 2, 12);
  session.replies.push(answer({ ok: true, values: ['Terrain_016'], as: 'console', kept: 0 }));
  await session.user.run('wax.runSelection');
  assert.ok(session.sent.at(-2).endsWith('end)("\\n\\ngame.MapName", "scratch.lua", nil, false, true)'), session.sent.at(-2).slice(-80));
  assert.ok(output(session).some((line) => line.endsWith('[run] line 3 of scratch.lua, as console')));

  session.user.select(1, 3, 1, 3);
  session.replies.push(answer({ ok: true, values: {}, as: 'console', kept: 0 }));
  await session.user.run('wax.runSelection');
  assert.ok(session.sent.at(-2).endsWith('end)("\\nprint(a)", "scratch.lua", nil, false, true)'));
});

test('Reload Mod saves the mod\'s files, asks the game, and says how it went', async (t) => {
  const session = start(t, makeWorkspace(t));
  await connect(session);
  const file = path.join(session.mods, 'Hello', 'init.lua');
  await session.user.open(file, 'return { changed = true }\n');
  session.replies.push(answer(true), answer({ core: 'table: 0x01', newest: 3, entries: {}, mods: LIST }));
  await session.user.run('wax.reloadMod', session.vscode.Uri.file(file));
  assert.equal(read(file), 'return { changed = true }\n');
  assert.ok(session.sent.at(-2).endsWith('end)("reload", "Hello")'));
  assert.equal(session.state.statusMessages.at(-1), '$(check) Wax: Hello reloaded in 4.3 ms');

  // from the view, for a mod that does not load
  session.replies.push(answer(true), answer({ core: 'table: 0x01', newest: 3, entries: {}, mods: LIST }));
  await session.user.run('wax.reloadMod', tree(session)[1].mod);
  assert.equal(session.state.messages.at(-1).text, 'Wax: Broken did not load: Broken/init.lua:2: attempt to call a nil value');
});

test('the view\'s buttons enable, disable, open and refresh', async (t) => {
  const session = start(t, makeWorkspace(t));
  await connect(session);
  const [hello, , off] = tree(session).map(({ mod }) => mod);
  session.replies.push(answer(true), answer({ core: 'table: 0x01', newest: 3, entries: {}, mods: LIST }));
  await session.user.run('wax.disableMod', hello);
  assert.ok(session.sent.at(-2).endsWith('end)("disable", "Hello")'));
  session.replies.push(answer(true), answer({ core: 'table: 0x01', newest: 3, entries: {}, mods: LIST }));
  await session.user.run('wax.enableMod', off);
  assert.ok(session.sent.at(-2).endsWith('end)("enable", "Off")'));

  await session.user.run('wax.openMod', hello);
  assert.equal(session.state.shown.at(-1), path.join(session.mods, 'Hello', 'init.lua'));

  const before = session.state.views.get('wax.mods').refreshed;
  session.replies.push(answer(true), answer({ core: 'table: 0x01', newest: 3, entries: {}, mods: LIST }));
  await session.user.run('wax.refreshMods');
  assert.ok(session.sent.at(-2).endsWith('end)("sync", nil)') || session.sent.at(-2).endsWith('end)("sync")'));
  assert.ok(session.state.views.get('wax.mods').refreshed > before);

  // with no file open and nothing clicked, the user is asked which mod
  session.vscode.window.activeTextEditor = undefined;
  let offered;
  session.state.reply = (kind, detail) => {
    if (kind !== 'pick') return undefined;
    offered = detail.items.map((item) => item.label);
    return detail.items[2];
  };
  await session.user.run('wax.openMod');
  assert.deepEqual(offered, ['Hello', 'Broken', 'Switched Off']);
  assert.equal(session.state.shown.at(-1), path.join(session.mods, 'Off', 'init.lua'));
});

test('a command that needs the game says so when it is not there', async (t) => {
  const session = start(t, makeWorkspace(t));
  session.app.game.running = async () => false;
  await session.user.open(path.join(session.mods, 'Hello', 'init.lua'));
  await session.user.run('wax.runFile');
  assert.equal(session.state.messages.at(-1).text, 'Wax: ICARUS is not running.');
  await session.user.run('wax.reloadMod');
  assert.equal(session.state.messages.at(-1).text, 'Wax: ICARUS is not running.');
});

test('the rest: show the log, open the documentation, set up editor support, stop scripts', async (t) => {
  const session = start(t, makeWorkspace(t), { 'wax.docsUrl': 'https://example.test/docs/' });
  await session.user.run('wax.showLog');
  assert.equal(session.state.channels.get('Wax').revealed, 1);
  await session.user.run('wax.openDocs');
  assert.deepEqual(session.state.external, ['https://example.test/docs/']);
  await session.user.run('wax.setUpEditor');
  assert.match(session.state.messages.at(-1).text, /editor support is set up for 1 mod /);
  await connect(session);
  session.replies.push(answer(3), answer({ core: 'table: 0x01', newest: 3, entries: {}, mods: LIST }));
  await session.user.run('wax.stopScripts');
  assert.match(session.state.statusMessages.at(-1), /removed 3 things/);
});

test('the documentation address has a default, and the setting for the runtime wins', async (t) => {
  const root = makeWorkspace(t);
  put(root, { 'elsewhere/Wax/Scripts/main.lua': '-- stage 0\n' });
  const session = start(t, root, { 'wax.runtimePath': path.join(root, 'elsewhere', 'Wax') });
  assert.equal(session.app.runtime, path.join(root, 'elsewhere', 'Wax'));
  assert.equal(session.app.modsDir, session.mods, 'luamods in the workspace is still where mods go');
  await session.user.run('wax.openDocs');
  assert.deepEqual(session.state.external, [manifest.contributes.configuration.properties['wax.docsUrl'].default]);
  assert.equal(session.state.external[0], 'https://wax-icarus.duckdns.org/');

  // changing the setting moves the connection
  session.state.settings['wax.runtimePath'] = '';
  session.user.events.configuration.fire({ affectsConfiguration: (key) => key === 'wax.runtimePath' });
  session.app.game.stop();
  assert.equal(session.app.runtime, path.join(root, 'wax', 'runtime'));
  assert.equal(session.app.game.runtime, session.app.runtime);
});

// A folder with nothing of Wax in it, open in VS Code.
function makeElsewhere(t) {
  const root = path.join(scratch(t), 'project');
  put(root, { 'notes.lua': 'print("not a mod")\n' });
  return root;
}

const NO_GAME = 'Wax: the ICARUS folder was not found. Choose the folder the game is installed in.';
const noWaxIn = (game) => `Wax is not installed in the game at ${game}. Download it, then run "Install Wax.cmd".`;
const relocate = (session, key) => session.user.events.configuration.fire({ affectsConfiguration: (asked) => asked === key });

test('when the game is not found the user is told once, with the two buttons, and not again by itself', async (t) => {
  const root = makeElsewhere(t);
  const session = start(t, root);
  assert.equal(session.app.runtime, null);
  assert.equal(session.state.contexts['wax.hasRuntime'], false);
  assert.equal(status(session).visible, false);
  assert.deepEqual(session.state.messages, [{ level: 'warning', text: NO_GAME, items: [CHOOSE, GET] }]);

  // nothing changed, so looking again says nothing
  relocate(session, 'wax.gamePath');
  session.user.events.folders.fire({});
  session.user.events.windowState.fire({ focused: true });
  // a path typed into the settings letter by letter is still the same thing missing
  for (const typed of [path.join(root, 'n'), path.join(root, 'not'), path.join(root, 'nothing')]) {
    session.state.settings['wax.gamePath'] = typed;
    relocate(session, 'wax.gamePath');
  }
  session.app.game.stop();
  await sleep(5);
  assert.equal(session.state.messages.length, 1);
  delete session.state.settings['wax.gamePath'];

  // the next time VS Code starts it is not said again
  const later = start(t, root, {}, { stored: session.context.stored });
  assert.deepEqual(later.state.messages, []);
  assert.equal(later.state.contexts['wax.hasRuntime'], false);

  // a command that needs the game says it, because the user asked for something
  await later.user.open(path.join(root, 'notes.lua'));
  await later.user.run('wax.runFile');
  assert.deepEqual(later.state.messages.map((message) => message.text), [NO_GAME]);
  assert.deepEqual(later.sent, [], 'nothing was sent anywhere');
  await later.user.run('wax.newMod');
  assert.equal(later.state.messages.length, 2);
  assert.deepEqual(later.state.messages[1].items, [CHOOSE, GET]);
});

test('a game without Wax: the message names the game, and Get Wax opens the download page', async (t) => {
  const root = makeElsewhere(t);
  const game = makeGame(path.join(scratch(t), 'steamapps', 'common', 'Icarus'));
  const session = start(t, root, {}, { steam: [{ game, runtime: null }], reply: (kind) => (kind === 'message' ? GET : undefined) });
  await sleep(5);
  assert.deepEqual(session.state.messages, [{ level: 'warning', text: noWaxIn(game), items: [GET, CHOOSE] }]);
  assert.deepEqual(session.state.external, [DOWNLOAD]);
  assert.equal(session.state.settingsSaved.length, 0);

  // Wax is installed while VS Code is open: coming back to the window finds it, and nothing more is said
  session.steam[0].runtime = makeRuntime(waxIn(game));
  session.user.events.windowState.fire({ focused: false });
  assert.equal(session.app.runtime, null);
  session.user.events.windowState.fire({ focused: true });
  session.app.game.stop();
  assert.equal(session.app.runtime, waxIn(game));
  assert.equal(session.app.modsDir, path.join(waxIn(game), 'mods'));
  assert.equal(session.state.contexts['wax.hasRuntime'], true);
  assert.equal(status(session).visible, true);
  assert.equal(session.state.messages.length, 1);
  assert.deepEqual(session.context.stored, {}, 'if Wax goes missing later, it is said again');
});

test('Choose the ICARUS Folder saves the game folder in the user\'s settings and finds Wax in it', async (t) => {
  const root = makeElsewhere(t);
  const game = makeGame(path.join(scratch(t), 'steamapps', 'common', 'Icarus'));
  const runtime = makeRuntime(waxIn(game));
  let dialog;
  const reply = (kind, detail) => {
    if (kind === 'message') return detail.items.includes(CHOOSE) ? CHOOSE : undefined;
    if (kind !== 'open') return undefined;
    dialog = detail;
    // a folder inside the game is as good as the game folder
    return path.join(game, 'Icarus', 'Binaries', 'Win64');
  };
  const session = start(t, root, { 'wax.runtimePath': path.join(root, 'gone') }, { reply });
  await sleep(10);
  session.app.game.stop();
  assert.deepEqual([dialog.canSelectFolders, dialog.canSelectFiles, dialog.canSelectMany, dialog.title], [true, false, false, 'Choose the ICARUS folder']);
  assert.deepEqual(session.state.settingsSaved, [
    { key: 'wax.gamePath', value: game, target: session.vscode.ConfigurationTarget.Global },
    { key: 'wax.runtimePath', value: undefined, target: session.vscode.ConfigurationTarget.Global },
  ]);
  assert.equal(session.app.runtime, runtime);
  assert.equal(session.app.game.runtime, runtime);
  assert.equal(session.state.contexts['wax.hasRuntime'], true);
  assert.deepEqual(session.state.messages.map((message) => [message.level, message.text]), [
    ['warning', `The setting wax.runtimePath is "${path.join(root, 'gone')}". That is not the ICARUS folder or the Wax folder. The game was not found anywhere else. Choose the folder ICARUS is installed in.`],
    ['info', `Wax: found Wax at ${runtime}.`],
  ]);
  assert.deepEqual(session.context.stored, {});
});

test('a folder that is not the game is turned down, nothing is saved, and the picker comes back only when asked', async (t) => {
  const root = makeElsewhere(t);
  let opened = 0;
  const answers = [undefined, CHOOSE];
  const session = start(t, root, {}, {
    stored: { 'wax.askedAbout': 'no game' },
    reply: (kind) => {
      if (kind === 'open') return ++opened < 3 ? root : undefined;
      return kind === 'message' ? answers.shift() : undefined;
    },
  });
  assert.deepEqual(session.state.messages, []);
  await session.user.run('wax.chooseGameFolder');
  assert.equal(opened, 1, 'the wrong folder was turned down and the picker did not come back by itself');
  assert.deepEqual(session.state.messages.map((message) => [message.text, message.items]), [
    [`Wax: "${root}" is not the ICARUS folder. Look for the folder named Icarus under steamapps\\common in your Steam library.`, [CHOOSE]],
  ]);
  await session.user.run('wax.chooseGameFolder');
  assert.equal(opened, 3, 'wrong again, the button pressed, then the picker closed without a choice');
  assert.equal(session.state.messages.length, 2);
  assert.deepEqual(session.state.settingsSaved, []);
  assert.equal(session.app.runtime, null);
});

test('choosing a game that has no Wax saves it and says once what is missing', async (t) => {
  const root = makeElsewhere(t);
  const game = makeGame(path.join(scratch(t), 'Icarus'));
  const session = start(t, root, {}, { stored: { 'wax.askedAbout': 'no game' }, reply: (kind) => (kind === 'open' ? game : undefined) });
  await session.user.run('wax.chooseGameFolder');
  session.app.game.stop();
  assert.deepEqual(session.state.settingsSaved.map((saved) => [saved.key, saved.value]), [['wax.gamePath', game]]);
  assert.deepEqual(session.state.messages, [{ level: 'warning', text: noWaxIn(game), items: [GET, CHOOSE] }]);
  assert.equal(session.app.found.game, game);
  relocate(session, 'wax.gamePath');
  session.app.game.stop();
  assert.equal(session.state.messages.length, 1);

  // the picker opens at the game it knows about
  let dialog;
  session.state.reply = (kind, detail) => { if (kind === 'open') dialog = detail; return undefined; };
  await session.user.run('wax.chooseGameFolder');
  assert.equal(dialog.defaultUri.fsPath, game);
});

test('a setting that points nowhere is named, and what was found instead is used', (t) => {
  const root = makeWorkspace(t);
  const session = start(t, root, { 'wax.gamePath': path.join(root, 'nowhere') });
  assert.equal(session.app.runtime, path.join(root, 'wax', 'runtime'));
  assert.deepEqual(session.state.messages.map((message) => [message.text, message.items]), [[
    `The setting wax.gamePath is "${path.join(root, 'nowhere')}". That is not the ICARUS folder or the Wax folder. The Wax folder at ${path.join(root, 'wax', 'runtime')} is used.`,
    ['Open Settings'],
  ]]);
  for (const typed of [path.join(root, 'nowhere'), path.join(root, 'nowhere else')]) {
    session.state.settings['wax.gamePath'] = typed;
    relocate(session, 'wax.gamePath');
  }
  session.app.game.stop();
  assert.equal(session.state.messages.length, 1, 'said once');
});

test('the game folder in the setting is enough: Wax is found inside it', (t) => {
  const root = makeElsewhere(t);
  const game = makeGame(path.join(scratch(t), 'Icarus'));
  const runtime = makeRuntime(waxIn(game));
  const session = start(t, root, { 'wax.gamePath': game });
  assert.equal(session.app.runtime, runtime);
  assert.equal(session.app.modsDir, path.join(runtime, 'mods'));
  assert.deepEqual(session.state.messages, []);
  assert.match(status(session).tooltip, /^Wax folder: /);
});

test('hovering a Wax name in a mod gives a link to its page in the docs', async (t) => {
  const session = start(t, makeWorkspace(t));
  const [{ provider, selector }] = session.state.hovers;
  assert.deepEqual(selector, { language: 'lua', scheme: 'file' });
  const text = 'local window = ui.Window({ title = "task.wait" })\nwindow:Button("ui.Notify", function() task.wait(1) end)\nlocal n = #text\n';
  const document = await session.user.open(path.join(session.mods, 'Hello', 'init.lua'), text);
  const at = (line, find) => provider.provideHover(document, new session.vscode.Position(line, text.split('\n')[line].indexOf(find) + 1));
  assert.equal(at(0, 'Window').contents.value, `Wax docs: [Windows](${DOCS}docs/gui/windows/)`);
  assert.equal(at(0, 'ui.').contents.value, `Wax docs: [ui](${DOCS}docs/reference/ui/)`);
  assert.equal(at(1, 'Button').contents.value, `Wax docs: [Button](${DOCS}docs/gui/controls/#button)`);
  assert.equal(at(1, 'wait').contents.value, `Wax docs: [Tasks](${DOCS}docs/tasks/)`);
  assert.equal(at(0, 'task.wait'), undefined, 'text inside a string is not code');
  assert.equal(at(1, 'ui.Notify'), undefined);
  assert.equal(at(2, 'text'), undefined);
  assert.equal(at(0, 'window'), undefined);

  // a Lua file that is not part of a mod is left alone
  put(session.root, { 'loose.lua': 'ui.Window({})\n' });
  const loose = await session.user.open(path.join(session.root, 'loose.lua'));
  assert.equal(provider.provideHover(loose, new session.vscode.Position(0, 4)), undefined);
});

test('every link the extension opens goes to the docs site or the download page', async (t) => {
  const session = start(t, makeWorkspace(t));
  await session.user.run('wax.openDocs');
  await session.user.run('wax.getWax');
  assert.deepEqual(session.state.external, [DOCS, DOWNLOAD]);
  // a docs address that is not a web address is not opened: the docs site is
  session.state.settings['wax.docsUrl'] = 'file:///C:/Windows/System32/calc.exe';
  await session.user.run('wax.openDocs');
  assert.equal(session.state.external.at(-1), DOCS);
});
test('a mod in the view opens into its scripts, its other files and the mods it uses', (t) => {
  const session = start(t, makeWorkspace(t));
  const hello = path.join(session.mods, 'Hello');
  fs.mkdirSync(path.join(hello, 'extras'), { recursive: true });
  fs.writeFileSync(path.join(hello, 'extras', 'Utils.lua'), 'return {}\n');
  fs.writeFileSync(path.join(hello, 'logo.png'), 'not really a picture');
  fs.mkdirSync(path.join(session.mods, 'Other'), { recursive: true });
  fs.writeFileSync(path.join(session.mods, 'Other', 'init.lua'), 'print("other")\n');
  fs.writeFileSync(path.join(session.mods, 'Other', 'mod.lua'), 'return { id = "Other", name = "Other", version = "1.0.0", dependencies = { "Hello", "Gone" } }\n');
  session.app.scanned = null;

  const { provider } = session.state.views.get('wax.mods');
  const mods = provider.getChildren();
  const of = (id) => mods.find((mod) => mod.id === id);
  const groups = (id) => provider.getChildren(of(id));
  const labels = (nodes) => nodes.map((node) => provider.getTreeItem(node).label);

  assert.deepEqual(labels(groups('Hello')), ['Scripts', 'Assets', 'Used by']);
  const [scripts, assets, usedBy] = groups('Hello');
  assert.equal(provider.getTreeItem(scripts).contextValue, 'part.scripts');
  const top = provider.getChildren(scripts);
  assert.equal(labels(top)[0], 'extras', 'folders come first');
  assert.ok(labels(top).includes('init.lua'));
  assert.deepEqual(labels(provider.getChildren(top[0])), ['Utils.lua']);
  const file = provider.getTreeItem(provider.getChildren(top[0])[0]);
  assert.equal(file.command.command, 'vscode.open');
  assert.deepEqual(labels(provider.getChildren(assets)), ['logo.png']);
  assert.deepEqual(labels(provider.getChildren(usedBy)), ['Other']);

  assert.deepEqual(labels(groups('Other')), ['Scripts', 'Assets', 'Uses']);
  assert.equal(provider.getTreeItem(groups('Other')[1]).description, 'none yet');
  const uses = provider.getChildren(groups('Other')[2]).map((node) => provider.getTreeItem(node));
  assert.deepEqual(uses.map((item) => [item.label, item.description, Boolean(item.command)]),
    [['Hello', '0.1.0', true], ['Gone', 'not in your mods', false]]);
});

test('New Folder makes a folder that shows in the tree, and Add Asset copies picked files into the mod', async (t) => {
  const session = start(t, makeWorkspace(t));
  const hello = path.join(session.mods, 'Hello');
  const { provider } = session.state.views.get('wax.mods');
  const mod = () => provider.getChildren().find((entry) => entry.id === 'Hello');
  const scripts = () => provider.getChildren(mod())[0];

  session.state.reply = (kind) => (kind === 'input' ? 'sounds' : undefined);
  await session.state.commands.get('wax.newFolder')(mod());
  assert.ok(fs.statSync(path.join(hello, 'sounds')).isDirectory());
  const top = provider.getChildren(scripts());
  assert.equal(provider.getTreeItem(top[0]).label, 'sounds', 'an empty folder shows');

  session.state.reply = (kind) => (kind === 'input' ? 'inner' : undefined);
  await session.state.commands.get('wax.newFolder')(top[0]);
  assert.ok(fs.statSync(path.join(hello, 'sounds', 'inner')).isDirectory());

  const picture = path.join(session.root, 'picked.png');
  fs.writeFileSync(picture, 'picture bytes');
  session.state.reply = (kind) => (kind === 'open' ? picture : undefined);
  await session.state.commands.get('wax.addAsset')(mod());
  assert.equal(fs.readFileSync(path.join(hello, 'picked.png'), 'utf8'), 'picture bytes');
  const assets = provider.getChildren(provider.getChildren(mod())[1]).map((node) => provider.getTreeItem(node).label);
  assert.deepEqual(assets, ['picked.png']);
});
