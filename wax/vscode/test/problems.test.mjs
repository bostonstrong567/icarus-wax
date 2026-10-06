// The game's log lines as problems on a mod's file and line. The messages are the ones the game's code writes.
import test from 'node:test';
import assert from 'node:assert/strict';
import { require } from './helpers.mjs';

const { resolveChunk, parseEntry, loadedMod, parseStatus, Tracker } = require('../lib/problems.js');
const { formatEntry, trimTrace, locateInChunk, firstLine } = require('../lib/logformat.js');

const mods = [
  { id: 'Hello', dir: 'D:\\Wax\\luamods\\Hello', files: ['init.lua', 'mod.lua', 'sub/util.lua', 'some/very/deep/folder/of/modules/that/goes/on/handler.lua'] },
  { id: 'Other', dir: 'D:\\Wax\\luamods\\Other', files: ['init.lua', 'mod.lua'] },
];
const error = (channel, message) => ({ id: 1, time: 0, level: 'error', channel, message, count: 1 });
const info = (channel, message) => ({ id: 1, time: 0, level: 'info', channel, message, count: 1 });

const LOAD_FAILURE = [
  "loading Hello: Hello/init.lua:19: attempt to index a nil value (global 'ui')",
  'stack traceback:',
  "\t[C]: in ?",
  '\tHello/init.lua:19: in main chunk',
  "\t[C]: in function 'xpcall'",
].join('\n');

test('an error while a mod loads lands on the file and line it names', () => {
  assert.deepEqual(parseEntry(error('Hello', LOAD_FAILURE), mods),
    { modId: 'Hello', file: 'init.lua', line: 19, message: "attempt to index a nil value (global 'ui')", kind: 'load' });
});

test('a syntax error, which has no traceback, does too', () => {
  assert.deepEqual(parseEntry(error('Hello', "loading Hello: Hello/sub/util.lua:7: unexpected symbol near '+'"), mods),
    { modId: 'Hello', file: 'sub/util.lua', line: 7, message: "unexpected symbol near '+'", kind: 'load' });
});

test('an error in a task or a callback is a problem that came up while running', () => {
  const task = "task: Hello/sub/util.lua:12: attempt to call a nil value (field 'missing')\nstack traceback:\n\tHello/sub/util.lua:12: in function <Hello/sub/util.lua:10>";
  assert.deepEqual(parseEntry(error('Hello', task), mods),
    { modId: 'Hello', file: 'sub/util.lua', line: 12, message: "attempt to call a nil value (field 'missing')", kind: 'runtime' });
  // the repeat of an error is logged as its first line only
  assert.equal(parseEntry(error('Hello', 'Frame: Hello/init.lua:41: boom'), mods).line, 41);
});

test('an error raised inside the library is put on the mod line that led there', () => {
  const message = [
    'loading Hello: ...Win64/ue4ss/Mods/Wax/Scripts/../Scripts/wax/gui/window.lua:88: title must be a string',
    'stack traceback:',
    "\t[C]: in function 'error'",
    '\t...Win64/ue4ss/Mods/Wax/Scripts/../Scripts/wax/gui/window.lua:88: in function <...>',
    '\tHello/init.lua:25: in main chunk',
  ].join('\n');
  const problem = parseEntry(error('Hello', message), mods);
  assert.deepEqual([problem.file, problem.line, problem.kind], ['init.lua', 25, 'load']);
  assert.match(problem.message, /title must be a string/);
});

test('a broken manifest is put on mod.lua, with or without a line', () => {
  const shortened = "Hello: mod.lua: ...ding/luamods/Hello/mod.lua:3: '}' expected near 'version'";
  assert.deepEqual(parseEntry(error('wax.mods', shortened), mods),
    { modId: 'Hello', file: 'mod.lua', line: 3, message: "'}' expected near 'version'", kind: 'load' });
  assert.deepEqual(parseEntry(error('wax.mods', 'Other: mod.lua: expected the file to return a table, got nil'), mods),
    { modId: 'Other', file: 'mod.lua', line: 1, message: 'expected the file to return a table, got nil', kind: 'load' });
});

test('file names Lua shortened are matched by their end', () => {
  assert.deepEqual(resolveChunk('Hello/init.lua', mods), { mod: mods[0], file: 'init.lua' });
  assert.deepEqual(resolveChunk('Hello\\sub\\util.lua', mods), { mod: mods[0], file: 'sub/util.lua' });
  assert.equal(resolveChunk('...les/that/goes/on/handler.lua', mods).file, 'some/very/deep/folder/of/modules/that/goes/on/handler.lua');
  assert.equal(resolveChunk('...4/ue4ss/Mods/Wax/mods/Other/mod.lua', mods).mod.id, 'Other');
  assert.equal(resolveChunk('D:/Wax/luamods/Other/init.lua', mods).mod.id, 'Other');
  // init.lua alone could be either mod's
  assert.equal(resolveChunk('...init.lua', mods), null);
  assert.equal(resolveChunk('Unknown/init.lua', mods), null);
  assert.equal(resolveChunk('...Win64/ue4ss/Mods/Wax/Scripts/../Scripts/wax/gui/root.lua', mods), null);
});

test('what names no mod file is not a problem', () => {
  assert.equal(parseEntry(error('console', "console:1: attempt to call a nil value (global 'GetCreatures')"), mods), null);
  assert.equal(parseEntry(error('wax', 'the GUI failed to start: ...Win64/ue4ss/Mods/Wax/Scripts/../Scripts/wax/gui/root.lua:76: script timeout'), mods), null);
  assert.equal(parseEntry(error('wax.mods', "Hello: needs mod 'Base', which is not installed"), mods), null);
  assert.equal(parseEntry(info('Hello', 'Hello/init.lua:3: only a note'), mods), null);
  assert.equal(parseEntry(error('Gone', 'loading Gone: Gone/init.lua:3: x'), mods), null);
  assert.equal(parseEntry(null, mods), null);
});

test('a clean load is recognised from the loader\'s own line', () => {
  assert.equal(loadedMod(info('wax.mods', 'Hello 0.1.0 loaded in 5.0 ms (reload #5)')), 'Hello');
  assert.equal(loadedMod(info('wax.mods', 'Hello  loaded in 12.3 ms')), 'Hello');
  assert.equal(loadedMod(info('wax.mods', 'Hello unloaded (reloading)')), null);
  assert.equal(loadedMod(info('Hello', 'Hello 0.1.0 loaded in 5.0 ms')), null);
  assert.equal(loadedMod(error('wax.mods', 'Hello 0.1.0 loaded in 5.0 ms')), null);
});

test('problems stay until the mod next loads cleanly', () => {
  const tracker = new Tracker();
  const dirs = new Map(mods.map((mod) => [mod.id, mod.dir]));
  assert.equal(tracker.apply([error('Hello', LOAD_FAILURE)], mods), true);
  assert.deepEqual(tracker.all(dirs).map((p) => [p.path, p.line]), [['D:/Wax/luamods/Hello/init.lua', 19]]);
  // the same line again changes nothing
  assert.equal(tracker.apply([error('Hello', LOAD_FAILURE)], mods), false);

  // another failed attempt replaces the first; another mod's clean load does not touch it
  tracker.apply([info('wax.mods', 'Other 1.0 loaded in 1.0 ms'), error('Hello', 'loading Hello: Hello/init.lua:4: oops')], mods);
  assert.deepEqual(tracker.all(dirs).map((p) => p.line), [4]);

  // it loads, then fails while running: only what came after the load is left
  tracker.apply([
    info('wax.mods', 'Hello 0.1.0 loaded in 2.0 ms (reload #1)'),
    error('Hello', 'task: Hello/sub/util.lua:12: late'),
    error('Hello', 'Frame: Hello/init.lua:41: boom'),
  ], mods);
  assert.deepEqual(tracker.all(dirs).map((p) => [p.file, p.line, p.kind]), [['sub/util.lua', 12, 'runtime'], ['init.lua', 41, 'runtime']]);

  assert.equal(tracker.apply([info('wax.mods', 'Hello 0.1.0 loaded in 2.0 ms (reload #2)')], mods), true);
  assert.deepEqual(tracker.all(dirs), []);
  assert.equal(tracker.apply([info('wax.mods', 'Hello 0.1.0 loaded in 2.0 ms (reload #3)')], mods), false);
});

test('the mod list fills in a failure or a clean load whose log line was missed', () => {
  const tracker = new Tracker();
  const dirs = new Map(mods.map((mod) => [mod.id, mod.dir]));
  const failed = { id: 'Hello', status: 'failed', error: "Hello/init.lua:19: attempt to index a nil value (global 'ui')" };
  assert.deepEqual(parseStatus(failed, mods), { modId: 'Hello', file: 'init.lua', line: 19, message: "attempt to index a nil value (global 'ui')", kind: 'load' });
  assert.equal(parseStatus({ id: 'Hello', status: 'failed', error: "mod.lua: ...ding/luamods/Hello/mod.lua:3: '}' expected" }, mods).file, 'mod.lua');
  assert.equal(parseStatus({ id: 'Hello', status: 'failed', error: "needs mod 'Base', which is not installed" }, mods), null);
  assert.equal(parseStatus({ id: 'Hello', status: 'loaded' }, mods), null);

  assert.equal(tracker.sync([failed, { id: 'Other', status: 'loaded' }], mods), true);
  assert.equal(tracker.all(dirs).length, 1);
  assert.equal(tracker.sync([failed, { id: 'Other', status: 'loaded' }], mods), false);
  assert.equal(tracker.sync([{ id: 'Hello', status: 'loaded' }, { id: 'Other', status: 'loaded' }], mods), true);
  assert.deepEqual(tracker.all(dirs), []);

  // a mod that is switched off, or gone from the game, keeps no problems
  tracker.apply([error('Other', 'task: Other/init.lua:2: x'), error('Hello', 'task: Hello/init.lua:2: x')], mods);
  assert.equal(tracker.sync([{ id: 'Other', status: 'disabled' }], mods), true);
  assert.deepEqual(tracker.all(dirs), []);
});

test('log lines are shown with their time, level and channel', () => {
  const at = new Date(2026, 9, 6, 2, 44, 12).getTime() / 1000;
  assert.equal(formatEntry({ time: at, level: 'info', channel: 'Hello', message: 'now on map Terrain_016', count: 1 }),
    '02:44:12 [info] [Hello] now on map Terrain_016');
  assert.equal(formatEntry({ time: at, level: 'error', channel: 'Hello', message: LOAD_FAILURE, count: 1 }), [
    "02:44:12 [error] [Hello] loading Hello: Hello/init.lua:19: attempt to index a nil value (global 'ui')",
    '    stack traceback:',
    '    [C]: in ?',
    '    Hello/init.lua:19: in main chunk',
    "    [C]: in function 'xpcall'",
  ].join('\n'));
  assert.equal(formatEntry({ time: at, level: 'warn', channel: 'Hello', message: 'again\nand more', count: 3, again: true }),
    '02:44:12 [warn] [Hello] (x3) again');
});

test('an error from running a file is placed in that file', () => {
  const trace = [
    "Hello/init.lua:19: attempt to index a nil value (global 'nope')",
    'stack traceback:',
    '\tHello/init.lua:19: in main chunk',
    "\t[C]: in function 'xpcall'",
    '\teval:70: in function <eval:69>',
  ].join('\n');
  assert.deepEqual(locateInChunk(trace, 'Hello/init.lua'), { line: 19, message: "attempt to index a nil value (global 'nope')" });
  assert.equal(trimTrace(trace).split('\n').length, 3);
  assert.equal(firstLine(trace), "Hello/init.lua:19: attempt to index a nil value (global 'nope')");
  assert.deepEqual(locateInChunk("scratch (1).lua:3: unexpected symbol near '+'", 'scratch (1).lua'), { line: 3, message: "unexpected symbol near '+'" });
  const inLibrary = 'window.lua:88: title must be a string\nstack traceback:\n\t[C]: in function \'error\'\n\tscratch.lua:4: in main chunk';
  assert.deepEqual(locateInChunk(inLibrary, 'scratch.lua'), { line: 4, message: 'window.lua:88: title must be a string' });
  assert.equal(locateInChunk('Wax is not running in the game', 'scratch.lua'), null);
});
