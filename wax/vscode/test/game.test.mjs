// The connection to the game: its states, and the Lua the extension sends, run against the real bridge and core
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { require, scratch, put, writeIndex, startStandInGame, waxIn, ROOT, EXTENSION, LUA } from './helpers.mjs';

const { Game, loadBridge, asArray } = require('../lib/game.js');
const chunks = require('../lib/chunks.js');
const { Tracker } = require('../lib/problems.js');
const { scanMods } = require('../lib/mods.js');
const { formatEntry, locateInChunk } = require('../lib/logformat.js');

const noLua = !fs.existsSync(LUA) && 'standalone Lua is not installed (scripts\\Get-Tools.ps1)';
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// A bridge that answers from a list of replies and remembers what it was sent. pings: what its ping command answers, when it has one.
function fakeBridge(replies, pings) {
  const sent = [];
  const client = {
    evalLua: async (code, options) => {
      sent.push({ code, options });
      const next = replies.shift();
      return next ?? { ok: false, error: 'timeout: the game did not pick up the request (game thread not ticking?)' };
    },
  };
  if (pings) client.ping = async () => pings.shift() ?? null;
  return { sent, load: async () => client };
}

const answer = (value) => ({ ok: true, values: [value], output: {} });
// What the game answers to Lua while developer mode is off.
const refusal = () => ({ ok: false, code: 'dev-off', output: {}, error: 'Developer mode is off, so this was not run. Wax only runs Lua sent from outside the game while a file named dev.txt is in its folder.' });

test('a request is one of the lua files, called with the values given', () => {
  const text = chunks.call('mods', 'reload', 'Hello');
  assert.ok(text.startsWith('(function(...)\n-- Asks the game'));
  assert.ok(text.endsWith('\nend)("reload", "Hello")'));
  assert.ok(chunks.call('run', 'return "a\nb"', 'x.lua', null, true, false).endsWith('end)("return \\"a\\nb\\"", "x.lua", nil, true, false)'));
});

test('every lua file the extension sends compiles', { skip: noLua }, (t) => {
  const dir = path.join(EXTENSION, 'lua');
  const files = fs.readdirSync(dir).filter((name) => name.endsWith('.lua')).map((name) => path.join(dir, name));
  assert.deepEqual(files.map((file) => path.basename(file)).sort(), ['mods.lua', 'poll.lua', 'run.lua', 'stop.lua']);
  const check = path.join(scratch(t), 'check.lua');
  fs.writeFileSync(check, 'for i = 1, #arg do assert(loadfile(arg[i])) end\nprint(#arg)\n');
  assert.equal(execFileSync(LUA, [check, ...files], { encoding: 'utf8' }).trim(), '4');
});

test('without the game nothing is sent through the bridge', async () => {
  const bridge = fakeBridge([]);
  const game = new Game({ runtime: 'X:/Wax', bridge: bridge.load, running: async () => false });
  game.active = true;
  await game.tick();
  game.stop();
  assert.equal(game.state, 'absent');
  assert.equal(bridge.sent.length, 0);
  await assert.rejects(game.reload('Hello'), /ICARUS is not running/);
});

test('a game that is there but silent is "busy"; one whose core did not start is "nocore"', async () => {
  const bridge = fakeBridge([undefined, undefined, answer({ core: false })]);
  const game = new Game({ runtime: 'X:/Wax', bridge: bridge.load, running: async () => true });
  const states = [];
  const problems = [];
  game.on('state', (state) => states.push(state));
  game.on('problem', (error) => problems.push(error.message));
  game.active = true;
  await game.tick();
  assert.equal(game.state, 'busy');
  await game.tick();
  await game.tick();
  game.stop();
  assert.equal(game.state, 'nocore');
  assert.deepEqual(states, ['busy', 'nocore']);
  assert.equal(bridge.sent[0].options.runtime, 'X:/Wax');
  // why it is not answering is said once, not on every try
  assert.deepEqual(problems, ['timeout: the game did not pick up the request (game thread not ticking?)']);
});

test('a game with developer mode off is "devoff": no Lua is sent to it again until a command says the mode is on', async () => {
  const mods = [{ id: 'Hello', name: 'Hello', status: 'loaded', enabled: true, generation: 1 }];
  const bridge = fakeBridge([refusal(), answer({ core: 'table: 0x01', newest: 1, entries: {}, mods }), refusal()],
    [{ dev: false, core: true }, { dev: false, core: true }, { dev: true, core: true }]);
  const game = new Game({ runtime: 'X:/Wax', bridge: bridge.load, running: async () => true });
  const states = [];
  const problems = [];
  game.on('state', (state) => states.push(state));
  game.on('problem', (error) => problems.push(error.message));
  game.active = true;
  await game.tick();
  assert.equal(game.state, 'devoff');
  assert.equal(game.connected, false);
  assert.deepEqual(game.mods, []);
  await game.tick();
  await game.tick();
  assert.equal(bridge.sent.length, 1, 'while the mode is off the game is asked with a command, not with Lua');
  await game.tick();
  assert.equal(game.state, 'connected');
  assert.equal(bridge.sent.length, 2);
  assert.deepEqual(game.mods.map((mod) => mod.id), ['Hello']);
  // the mode goes off again while connected: the next look says so
  await game.tick();
  game.stop();
  assert.deepEqual(states, ['devoff', 'connected', 'devoff']);
  assert.deepEqual(problems, [], 'a game that answers is not a problem');
});

test('what the user asks for while developer mode is off fails with the game\'s own words and a code', async () => {
  const bridge = fakeBridge([refusal(), refusal(), refusal()]);
  const game = new Game({ runtime: 'X:/Wax', bridge: bridge.load, running: async () => true });
  for (const ask of [() => game.reload('Hello'), () => game.setEnabled('Hello', true), () => game.run({ source: 'return 1', chunkname: 'x.lua' })]) {
    await assert.rejects(ask(), (error) => error.code === 'dev-off' && /^Developer mode is off, so this was not run\./.test(error.message));
  }
  assert.equal(bridge.sent.length, 3);
});

test('a bridge client that cannot be loaded is reported, not mistaken for a missing game', async () => {
  const game = new Game({ runtime: 'X:/Wax', bridge: () => Promise.reject(new Error('bridge.mjs is missing from the extension')), running: async () => true });
  const problems = [];
  game.on('problem', (error) => problems.push(error.message));
  game.active = true;
  await game.tick();
  game.stop();
  assert.deepEqual(problems, ['bridge.mjs is missing from the extension']);
  await assert.rejects(game.reload('Hello'), /bridge\.mjs is missing/);
});

test('a look at the game hands on new log lines and the mod list, and remembers where it was', async () => {
  const mods = [{ id: 'Hello', name: 'Hello', version: '0.1.0', status: 'loaded', enabled: true, generation: 1, owned: 4 }];
  const bridge = fakeBridge([
    answer({ core: 'table: 0x01', newest: 12, entries: [{ id: 11, level: 'info', channel: 'wax', message: 'a', count: 1 }, { id: 12, level: 'info', channel: 'wax', message: 'b', count: 2 }], mods }),
    answer({ core: 'table: 0x01', newest: 12, entries: {}, mods: [{ ...mods[0], owned: 3 }] }),
    answer({ core: 'table: 0x01', newest: 13, entries: [{ id: 13, level: 'warn', channel: 'Hello', message: 'c', count: 1 }], mods: {} }),
    undefined,
  ]);
  const game = new Game({ runtime: 'X:/Wax', bridge: bridge.load, running: async () => false });
  const seen = { log: [], mods: 0, states: [] };
  game.on('log', (entries) => seen.log.push(...entries.map((entry) => entry.message)));
  game.on('mods', () => { seen.mods += 1; });
  game.on('state', (state) => seen.states.push(state));

  assert.equal(await game.poll(), true);
  assert.equal(game.connected, true);
  assert.deepEqual([game.core, game.lastId, game.lastCount], ['table: 0x01', 12, 2]);
  assert.ok(bridge.sent[0].code.endsWith('end)("", -1, 0, 40)'), 'the first look asks for the last lines');

  // an empty list comes back from the game as {}, and a count that only moves is not a change
  assert.equal(await game.poll(), true);
  assert.ok(bridge.sent[1].code.endsWith('end)("table: 0x01", 12, 2, 40)'));
  assert.equal(seen.mods, 1);

  assert.equal(await game.poll(), true);
  assert.deepEqual(game.mods, []);
  assert.deepEqual([game.lastId, game.lastCount, seen.mods], [13, 1, 2]);
  assert.deepEqual(seen.log, ['a', 'b', 'c']);

  // the game stops answering and is no longer running
  game.active = true;
  await game.tick();
  game.stop();
  assert.deepEqual(seen.states, ['connected', 'absent']);
  assert.deepEqual(asArray({}), []);
});

test('no runtime folder, no connection', async () => {
  const bridge = fakeBridge([]);
  const game = new Game({ bridge: bridge.load, running: async () => true });
  assert.equal(game.state, 'unset');
  game.start();
  assert.equal(game.timer, null);
  await assert.rejects(game.call('poll'), /was not found/);
  game.setRuntime('X:/Wax');
  assert.equal(game.state, 'absent');
  assert.notEqual(game.timer, null);
  game.setRuntime(null);
  game.stop();
  assert.equal(game.state, 'unset');
});

test('the bridge client is the workspace\'s own beside a source checkout, the packed copy otherwise', async (t) => {
  const live = await loadBridge(EXTENSION);
  assert.equal(typeof live.evalLua, 'function');
  assert.equal(live.ROOT, ROOT);
  const packed = path.join(scratch(t), 'ext');
  put(packed, { 'bundled/bridge.mjs': 'export const marker = "packed";\n' });
  assert.equal((await loadBridge(packed)).marker, 'packed');
  await assert.rejects(loadBridge(path.join(packed, 'bundled')), /bridge\.mjs is missing/);
});

test('against the real bridge and the real Wax core', { skip: noLua }, async (t) => {
  const dir = waxIn(scratch(t));
  const modsDir = path.join(dir, 'mods');
  const index = () => writeIndex(dir, modsDir);
  put(dir, {
    'mods/Alpha/mod.lua': 'return { name = "Alpha Mod", version = "1.2.3" }\n',
    'mods/Alpha/init.lua': 'shared_value = 7\nprint("alpha is up")\nreturn { answer = 42 }\n',
    'mods/Broken/init.lua': 'local nothing = nil\n\nreturn nothing.field\n',
  });
  index();
  const standIn = await startStandInGame(t, dir);

  const bridge = await import(pathToFileURL(path.join(ROOT, 'wax', 'cli', 'bridge.mjs')).href);
  const game = new Game({ runtime: dir, bridge: async () => bridge, running: async () => true });
  const tracker = new Tracker();
  const log = [];
  game.on('log', (entries) => {
    log.push(...entries);
    tracker.apply(entries, scanMods(modsDir));
  });
  game.on('mods', (mods) => { if (game.connected) tracker.sync(mods, scanMods(modsDir)); });
  const dirs = () => new Map(scanMods(modsDir).map((mod) => [mod.id, mod.dir]));
  const mod = (id) => game.mods.find((entry) => entry.id === id);
  const logged = (text) => log.some((entry) => entry.message.includes(text));

  await t.test('the first look connects, lists the mods and reads the log so far', async () => {
    assert.equal(await game.poll(), true);
    assert.equal(game.state, 'connected');
    assert.deepEqual(game.mods.map((entry) => [entry.id, entry.name, entry.version, entry.status, entry.enabled]),
      [['Alpha', 'Alpha Mod', '1.2.3', 'loaded', true], ['Broken', 'Broken', undefined, 'failed', true]]);
    assert.equal(mod('Alpha').dir, path.join(modsDir, 'Alpha').replaceAll('\\', '/'));
    assert.ok(logged('alpha is up'));
    assert.ok(logged('Alpha 1.2.3 loaded in'));
    assert.match(formatEntry(log.find((entry) => entry.message === 'alpha is up')), /^\d\d:\d\d:\d\d \[info\] \[Alpha\] alpha is up$/);
  });

  await t.test('the mod that failed to load is a problem on its file and line', () => {
    assert.match(mod('Broken').error, /^Broken\/init\.lua:3: attempt to index a nil value/);
    const problems = tracker.all(dirs());
    assert.equal(problems.length, 1);
    assert.equal(problems[0].path, path.join(modsDir, 'Broken', 'init.lua').replaceAll('\\', '/'));
    assert.deepEqual([problems[0].line, problems[0].kind], [3, 'load']);
    assert.match(problems[0].message, /^attempt to index a nil value/);
  });

  await t.test('a second look brings nothing twice', async () => {
    const before = log.length;
    assert.equal(await game.poll(), true);
    assert.equal(log.length, before);
  });

  await t.test('reloading the fixed mod clears its problem', async () => {
    put(modsDir, { 'Broken/init.lua': 'return { fixed = true }\n' });
    await game.reload('Broken');
    assert.equal(mod('Broken').status, 'loaded');
    assert.equal(mod('Broken').error, undefined);
    assert.ok(logged('Broken  loaded in'));
    assert.deepEqual(tracker.all(dirs()), []);
  });

  await t.test('a file outside any mod runs like a command in the console', async () => {
    const result = await game.run({ source: 'local n = 1 + 1\nreturn n, "two", { a = 1 }, nil', chunkname: 'scratch.lua', fresh: true });
    assert.deepEqual([result.ok, result.as, result.waiting], [true, 'console', undefined]);
    assert.deepEqual(result.values, ['2', 'two', '{ a = 1 }', 'nil']);
    const nothing = await game.run({ source: 'local unused = 1', chunkname: 'scratch.lua', fresh: true });
    assert.deepEqual([nothing.ok, nothing.values], [true, []]);
  });

  await t.test('a file of a loaded mod runs as that mod', async () => {
    const result = await game.run({ source: 'print("from the editor")\nreturn mod.id, shared_value', chunkname: 'Alpha/extra.lua', modId: 'Alpha', fresh: true });
    assert.deepEqual([result.ok, result.as, result.values], [true, 'Alpha', ['Alpha', '7']]);
    assert.equal(log.find((entry) => entry.message === 'from the editor').channel, 'Alpha');
    const elsewhere = await game.run({ source: 'return mod.id, shared_value', chunkname: 'Gone/init.lua', modId: 'Gone', fresh: true });
    assert.deepEqual([elsewhere.as, elsewhere.values], ['console', ['console', 'nil']]);
  });

  await t.test('a selection runs as an expression when it is one, with the file\'s line numbers', async () => {
    const value = await game.run({ source: '\n\n\nshared_value * 2', chunkname: 'Alpha/init.lua', modId: 'Alpha', expression: true });
    assert.deepEqual(value.values, ['14']);
    const statement = await game.run({ source: '\n\n\nlocal x = 5', chunkname: 'Alpha/init.lua', modId: 'Alpha', expression: true });
    assert.deepEqual([statement.ok, statement.values], [true, []]);
    const failed = await game.run({ source: '\n\n\nerror("boom")', chunkname: 'Alpha/init.lua', modId: 'Alpha', expression: true });
    assert.equal(failed.ok, false);
    assert.deepEqual(locateInChunk(failed.error, 'Alpha/init.lua'), { line: 4, message: 'boom' });
  });

  await t.test('errors come back with the file and line', async () => {
    const runtime = await game.run({ source: 'local t = nil\nreturn t.x', chunkname: 'scratch.lua', fresh: true });
    assert.equal(runtime.ok, false);
    assert.match(runtime.error, /^scratch\.lua:2: attempt to index a nil value \(local 't'\)\nstack traceback:/);
    const syntax = await game.run({ source: 'local = 5', chunkname: 'scratch.lua', fresh: true });
    assert.equal(syntax.ok, false);
    assert.deepEqual(locateInChunk(syntax.error, 'scratch.lua').line, 1);
  });

  await t.test('code that waits keeps running, and what it does later reaches the log', async () => {
    const result = await game.run({ source: 'task.wait(0.05)\nprint("after the wait")\nerror("late failure")', chunkname: 'waits.lua', fresh: true });
    assert.deepEqual([result.ok, result.waiting, result.values], [true, true, []]);
    for (let i = 0; i < 100 && !logged('late failure'); i++) {
      await sleep(20);
      await game.poll();
    }
    assert.ok(logged('after the wait'));
    const failure = log.find((entry) => entry.message.includes('late failure'));
    assert.deepEqual([failure.level, failure.channel], ['error', 'console']);
    assert.match(failure.message, /^run waits\.lua: waits\.lua:3: late failure/);
  });

  await t.test('what a run leaves behind goes when the file is run again, or when scripts are stopped', async () => {
    const loop = 'ticks = (ticks or 0)\ntask.spawn(function() while true do ticks = ticks + 1 task.wait(0.01) end end)\nreturn "started"';
    const first = await game.run({ source: loop, chunkname: 'loop.lua', fresh: true });
    assert.deepEqual([first.values, first.kept], [['started'], 1]);
    const again = await game.run({ source: loop, chunkname: 'loop.lua', fresh: true });
    assert.equal(again.kept, 1, 'the first loop was removed before the second started');
    const selection = await game.run({ source: 'task.spawn(function() while true do task.wait(0.01) end end)', chunkname: 'loop.lua', expression: true });
    assert.equal(selection.kept, 2, 'a selection adds to what the file set up');
    assert.equal(await game.stopScripts(), 2);
    assert.equal(await game.stopScripts(), 0);
    const before = (await game.run({ source: 'return ticks', chunkname: 'peek.lua', fresh: true })).values[0];
    await sleep(80);
    assert.equal((await game.run({ source: 'return ticks', chunkname: 'peek.lua', fresh: true })).values[0], before, 'the loops are gone');
  });

  await t.test('a mod can be switched off and on again', async () => {
    await game.setEnabled('Alpha', false);
    assert.deepEqual([mod('Alpha').status, mod('Alpha').enabled], ['disabled', false]);
    await game.setEnabled('Alpha', true);
    assert.deepEqual([mod('Alpha').status, mod('Alpha').enabled], ['loaded', true]);
    await assert.rejects(game.setEnabled('Nobody', true), /no mod named 'Nobody'/);
  });

  await t.test('a mod made while the game runs is found on refresh and held switched off', async () => {
    put(modsDir, { 'Fresh/init.lua': 'print("fresh is up")\nreturn {}\n' });
    index();
    await game.refresh();
    assert.deepEqual([mod('Fresh').status, mod('Fresh').enabled, mod('Fresh').fresh], ['disabled', false, true]);
    await game.setEnabled('Fresh', true);
    assert.equal(mod('Fresh').status, 'loaded');
    assert.ok(logged('fresh is up'));
  });

  await t.test('an error in a running mod becomes a problem and goes when the mod loads cleanly', async () => {
    put(modsDir, { 'Alpha/init.lua': 'task.delay(0.02, function()\n    local missing = nil\n    missing()\nend)\nreturn {}\n' });
    await game.reload('Alpha');
    for (let i = 0; i < 100 && !tracker.all(dirs()).length; i++) {
      await sleep(20);
      await game.poll();
    }
    const problems = tracker.all(dirs());
    assert.deepEqual(problems.map((problem) => [problem.modId, problem.file, problem.line, problem.kind]), [['Alpha', 'init.lua', 3, 'runtime']]);
    put(modsDir, { 'Alpha/init.lua': 'return {}\n' });
    await game.reload('Alpha');
    assert.deepEqual(tracker.all(dirs()), []);
  });

  await t.test('a message logged again only moves its counter', async () => {
    await game.run({ source: 'log:warn("same again")', chunkname: 'repeat.lua', fresh: true });
    await game.run({ source: 'log:warn("same again")', chunkname: 'repeat.lua', fresh: true });
    const lines = log.filter((entry) => entry.message === 'same again');
    assert.deepEqual(lines.map((entry) => [entry.count, entry.again]), [[1, false], [2, true]]);
    assert.match(formatEntry(lines[1]), /\[warn\] \[console\] \(x2\) same again$/);
  });

  await t.test('a restarted core is read from its beginning again', async () => {
    const before = log.length;
    await game.run({ source: 'local old = Wax\nlocal copy = {}\nfor key, value in pairs(old) do copy[key] = value end\nraw.Wax = copy', chunkname: 'swap.lua', fresh: true });
    await game.poll();
    assert.ok(log.length > before + 5, 'the log was read again from the start of what is kept');
    assert.equal(game.state, 'connected');
  });

  assert.equal(standIn.stderr, '');
});

test('against the real bridge, in a game without dev.txt: commands are answered and Lua is not run', { skip: noLua }, async (t) => {
  const dir = waxIn(scratch(t));
  const modsDir = path.join(dir, 'mods');
  const counts = 'raw.MARKED_RAN = (raw.MARKED_RAN or 0) + 1\nreturn {}\n';
  put(dir, {
    'mods/Alpha/mod.lua': 'return { name = "Alpha Mod", version = "1.2.3" }\n',
    'mods/Alpha/init.lua': 'return { made = "first" }\n',
    'mods/Marked/mod.lua': 'return { name = "Marked Mod", version = "1.0.0" }\n',
    'mods/Marked/init.lua': counts,
  });
  const standIn = await startStandInGame(t, dir, { dev: false });
  const bridge = await import(pathToFileURL(path.join(ROOT, 'wax', 'cli', 'bridge.mjs')).href);
  const game = new Game({ runtime: dir, bridge: async () => bridge, running: async () => true });
  const at = { runtime: dir, timeoutSec: 10 };

  await t.test('Lua is refused in the game\'s own words, and the game is "devoff"', async () => {
    const refused = await bridge.evalLua('raw.RAN = true return 1 + 1', at);
    assert.deepEqual([refused.ok, refused.code], [false, 'dev-off']);
    assert.match(refused.error, /^Developer mode is off, so this was not run\. .*dev\.txt.*"Wax: Switch Developer Mode On"/);
    assert.match(bridge.devModeHelp(dir), /put a file named dev\.txt in that folder/);
    assert.equal(await game.poll(), true);
    assert.equal(game.state, 'devoff');
    assert.deepEqual(game.mods, []);
    await assert.rejects(game.reload('Alpha'), (error) => error.code === 'dev-off');
    await assert.rejects(game.run({ source: 'return 1', chunkname: 'x.lua' }), (error) => error.code === 'dev-off');
  });

  await t.test('ping says the game is there, that the core is up and that developer mode is off', async () => {
    const info = await bridge.ping(5, { runtime: dir });
    assert.deepEqual([info.thread, info.core, info.dev, typeof info.frame], ['game', true, false, 'number']);
  });

  await t.test('mod-added for a mod the player did not have lists it switched off', async () => {
    put(modsDir, { 'Arrives/mod.lua': 'return { name = "Arrives Mod", version = "2.0.0" }\n', 'Arrives/init.lua': 'raw.ARRIVES_RAN = true\nreturn {}\n' });
    const reply = await bridge.command('mod-added', { id: 'Arrives' }, at);
    assert.equal(reply.ok, true);
    assert.deepEqual(reply.values[0], { id: 'Arrives', name: 'Arrives Mod', version: '2.0.0', status: 'disabled', enabled: false, fresh: true });
  });

  await t.test('mod-added for a mod that was running loads its new files', async () => {
    put(modsDir, { 'Alpha/mod.lua': 'return { name = "Alpha Mod", version = "1.3.0" }\n', 'Alpha/init.lua': 'return { made = "second" }\n' });
    const reply = await bridge.command('mod-added', { id: 'Alpha' }, at);
    assert.deepEqual(reply.values[0], { id: 'Alpha', name: 'Alpha Mod', version: '1.3.0', status: 'loaded', enabled: true, fresh: false });
  });

  await t.test('mod-added for a copy that carries wax.new holds it, though the player had the mod and it was running', async () => {
    // deleted by hand, then put back by the button, which marks a copy it puts where no folder was
    fs.rmSync(path.join(modsDir, 'Marked'), { recursive: true });
    put(modsDir, {
      'Marked/mod.lua': 'return { name = "Marked Mod", version = "1.1.0" }\n', 'Marked/init.lua': counts,
      'Marked/wax.origin': 'id=Marked\nversion=1.1.0\n', 'Marked/wax.new': 'new\n',
    });
    const reply = await bridge.command('mod-added', { id: 'Marked' }, at);
    assert.equal(reply.ok, true);
    assert.deepEqual(reply.values[0], { id: 'Marked', name: 'Marked Mod', version: '1.1.0', status: 'disabled', enabled: false, fresh: true });
  });

  await t.test('a command that is not one, or names no mod, is refused with a code', async () => {
    const code = async (name, values) => {
      const reply = await bridge.command(name, values, at);
      return [reply.ok, reply.code];
    };
    assert.deepEqual(await code('mod-added', { id: 'Ghost' }), [false, 'no-mod']);
    assert.deepEqual(await code('mod-added', { id: '../Alpha' }), [false, 'bad-request']);
    assert.deepEqual(await code('mod-added', {}), [false, 'bad-request']);
    assert.deepEqual(await code('mod-added', { id: 'Alpha', name: 'Another name' }), [false, 'bad-request']);
    assert.deepEqual(await code('ping', { id: 'Alpha' }), [false, 'bad-request']);
    assert.deepEqual(await code('run', { code: 'raw.RAN = true' }), [false, 'unknown-command']);
    assert.throws(() => bridge.command('Mod Added'), /not the name of a command/);
    assert.throws(() => bridge.command('mod-added', { id: 'Alpha\n--wax:ping' }), /cannot be sent/);
  });

  await t.test('with dev.txt put there the next look connects, and shows what the player was told and that nothing ran', async () => {
    fs.writeFileSync(path.join(dir, 'dev.txt'), '');
    const log = [];
    game.on('log', (entries) => log.push(...entries));
    assert.equal(await game.poll(), true);
    assert.equal(game.state, 'connected');
    assert.deepEqual(game.mods.map((mod) => [mod.id, mod.status, mod.fresh ?? false]),
      [['Alpha', 'loaded', false], ['Arrives', 'disabled', true], ['Marked', 'disabled', true]]);
    assert.deepEqual(log.filter((entry) => entry.channel === 'notification').map((entry) => entry.message), [
      'New mod: Arrives Mod 2.0.0 was added. It stays switched off until you switch it on in the Mods page.',
      'Mods: Alpha Mod 1.3.0 was put in and is running.',
      'New mod: Marked Mod 1.1.0 was added. It stays switched off until you switch it on in the Mods page.',
    ]);
    const ran = await game.run({ source: 'return raw.RAN, raw.ARRIVES_RAN, exports.Alpha.made, raw.MARKED_RAN', chunkname: 'peek.lua', fresh: true });
    assert.deepEqual(ran.values, ['nil', 'nil', 'second', '1'], 'the marked copy has not run: the one count is from before it was replaced');
    assert.equal((await bridge.ping(5, { runtime: dir })).dev, true);
  });

  await t.test('switching the marked mod on takes its mark away and runs it', async () => {
    await game.setEnabled('Marked', true);
    assert.equal(game.mods.find((mod) => mod.id === 'Marked').status, 'loaded');
    assert.equal(fs.existsSync(path.join(modsDir, 'Marked', 'wax.new')), false);
    assert.ok(fs.existsSync(path.join(modsDir, 'Marked', 'wax.origin')));
  });

  await t.test('and with it taken away again the game is back to commands only', async () => {
    fs.rmSync(path.join(dir, 'dev.txt'));
    assert.equal(await game.poll(), true);
    assert.equal(game.state, 'devoff');
    assert.equal(await game.poll(), true);
    assert.equal(game.state, 'devoff');
  });

  assert.equal(standIn.stderr, '');
});
