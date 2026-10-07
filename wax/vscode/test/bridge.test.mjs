// The bridge client's own care: who may use the folders it makes, and what it is willing to start
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { scratch, put, ROOT } from './helpers.mjs';

const bridge = await import(pathToFileURL(path.join(ROOT, 'wax', 'cli', 'bridge.mjs')).href);
const ICACLS = path.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'icacls.exe');
const notWindows = process.platform !== 'win32' && 'the folders are limited with icacls, which is Windows only';

// Who may use a folder, as icacls lists it: one entry for each account or group.
function entries(dir) {
  const out = execFileSync(ICACLS, [dir], { encoding: 'utf8' });
  return out.split(/\r?\n/).filter((line) => /:\(/.test(line)).map((line) => line.replace(dir, '').trim());
}

test('the folders requests go through are made for the current user, the system and the administrators only', { skip: notWindows }, async (t) => {
  const runtime = path.join(scratch(t), 'Wax');
  fs.mkdirSync(runtime);
  const before = entries(runtime);
  assert.ok(before.some((entry) => /\(I\)/.test(entry)), 'a folder made the usual way takes its permissions from the folder above');

  const warnings = [];
  const reply = await bridge.command('ping', {}, { runtime, timeoutSec: 0.3, warn: (text) => warnings.push(text) });
  assert.equal(reply.ok, false, 'no game is reading that folder');
  assert.deepEqual(warnings, []);
  for (const name of ['run', 'run\\in', 'run\\out']) {
    const now = entries(path.join(runtime, name));
    assert.equal(now.length, 3, `${name}: ${now.join(' | ')}`);
    for (const entry of now) {
      assert.ok(!/\(I\)/.test(entry), `${name} takes nothing from the folder above: ${entry}`);
      assert.match(entry, /\(OI\)\(CI\)\(F\)$/, `${name}: ${entry}`);
    }
  }
  assert.deepEqual(entries(runtime), before, 'the Wax folder itself is left as it was');
  // what is put there afterwards can still be written and read by this user
  fs.writeFileSync(path.join(runtime, 'run', 'in', 'probe'), 'x');
  assert.equal(fs.readFileSync(path.join(runtime, 'run', 'in', 'probe'), 'utf8'), 'x');
});

test('folders that are there already are left as they are', { skip: notWindows }, async (t) => {
  const runtime = path.join(scratch(t), 'Wax');
  fs.mkdirSync(path.join(runtime, 'run', 'in'), { recursive: true });
  fs.mkdirSync(path.join(runtime, 'run', 'out'));
  const before = ['run', 'run\\in', 'run\\out'].map((name) => entries(path.join(runtime, name)));
  await bridge.evalLua('return 1', { runtime, timeoutSec: 0.3 });
  assert.deepEqual(['run', 'run\\in', 'run\\out'].map((name) => entries(path.join(runtime, name))), before);
});

test('a folder that cannot be limited is a warning, and the request still goes out', { skip: notWindows }, async (t) => {
  const missing = path.join(scratch(t), 'not there');
  assert.match(bridge.limitToUser(missing), /\S/);
  assert.equal(bridge.limitToUser(scratch(t)), null);
});

test('only a file named steam.exe, given by its full path, is started', (t) => {
  const dir = scratch(t);
  put(dir, { 'Steam/steam.exe': '', 'Steam/calc.exe': '', 'Other/Steam.EXE': '' });
  fs.mkdirSync(path.join(dir, 'Folder', 'steam.exe'), { recursive: true });
  assert.equal(bridge.steamProblem(path.join(dir, 'Steam', 'steam.exe')), null);
  assert.equal(bridge.steamProblem(path.join(dir, 'Other', 'Steam.EXE')), null);
  assert.equal(bridge.steamProblem(path.join(dir, 'Steam', 'steam.exe').replaceAll('\\', '/')), null);
  assert.match(bridge.steamProblem(path.join(dir, 'Steam', 'calc.exe')), /is not a file named steam\.exe$/);
  assert.match(bridge.steamProblem('C:\\Windows\\System32\\cmd.exe'), /is not a file named steam\.exe$/);
  assert.match(bridge.steamProblem(path.join(dir, 'Steam', 'steam.exe') + ' -applaunch 1'), /is not a file named steam\.exe$/);
  assert.match(bridge.steamProblem('steam.exe'), /is not a full path$/);
  assert.match(bridge.steamProblem('.\\steam.exe'), /is not a full path$/);
  assert.match(bridge.steamProblem(path.join(dir, 'Gone', 'steam.exe')), /there is no such file$/);
  assert.match(bridge.steamProblem(path.join(dir, 'Folder', 'steam.exe')), /is not a file$/);
  for (const nothing of [undefined, null, '', '   ', 5, {}]) assert.match(bridge.steamProblem(nothing), /names no steamExe/);
});

test('start says why Steam is not started when wax.config.json names something else', () => {
  const source = fs.readFileSync(path.join(ROOT, 'wax', 'cli', 'bridge.mjs'), 'utf8');
  const start = source.slice(source.indexOf('export async function start('));
  assert.ok(start.indexOf('steamProblem(steamExe)') > 0 && start.indexOf('steamProblem(steamExe)') < start.indexOf('spawn(steamExe'),
    'the check comes before the program is started');
  // nothing is started through a shell, and Windows' own programs are named by their full path
  assert.ok(!/shell:\s*true/.test(source));
  for (const tool of ['tasklist', 'taskkill', 'icacls', 'whoami']) {
    assert.ok(source.includes(`windowsTool('${tool}.exe')`), tool);
    assert.ok(!new RegExp(`execFileSync\\('${tool}`).test(source), `${tool} by its bare name`);
  }
});
