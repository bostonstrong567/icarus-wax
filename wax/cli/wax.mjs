#!/usr/bin/env node
// Wax CLI: drive the live game from outside it
import fs from 'node:fs';
import { evalLua, gameRunning, ping, start, stop, ue4ssLogPath } from './bridge.mjs';
import { sync, watch } from './mods.mjs';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function option(args, name, fallback) {
  const i = args.indexOf(name);
  if (i === -1) return fallback;
  const value = args[i + 1];
  args.splice(i, 2);
  return value;
}

function flag(args, name) {
  const i = args.indexOf(name);
  if (i === -1) return false;
  args.splice(i, 1);
  return true;
}

const args = process.argv.slice(2);
const command = args.shift();
let result;
switch (command) {
  case 'start':
    result = await start({ timeoutSec: Number(option(args, '--timeout', 240)), windowed: flag(args, '--windowed') });
    break;
  case 'status': {
    const running = gameRunning();
    const bridge = running ? await ping() : null;
    let state = 'game not running';
    if (running) state = bridge ? 'ready' : 'game running, game thread not answering (loading, paused, hung, or Wax not installed)';
    result = { state, gameRunning: running, bridge };
    break;
  }
  case 'perf': {
    // Measures for a few seconds: the game's frame times and what each part of Wax costs per frame.
    const seconds = Number(option(args, '--seconds', 10));
    const begun = await evalLua('Wax.perf.reset() return true', { timeoutSec: 10 });
    if (!begun.ok) { result = begun; break; }
    await sleep(seconds * 1000);
    const reply = await evalLua('return Wax.perf.report()', { timeoutSec: 10 });
    if (!reply.ok) { result = reply; break; }
    const r = reply.values[0];
    const sections = Array.isArray(r.sections) ? r.sections : [];
    console.log(`${r.frames} frames in ${r.seconds.toFixed(1)} s  (${r.fps.toFixed(1)} fps, average ${r.frame_ms.avg.toFixed(2)} ms, worst ${r.frame_ms.max.toFixed(1)} ms)`);
    console.log(`frames over 33 ms: ${r.hitches.over33ms}   over 50 ms: ${r.hitches.over50ms}   over 100 ms: ${r.hitches.over100ms}`);
    console.log(`Wax per frame: ${(r.wax_us_per_frame / 1000).toFixed(3)} ms  (${(r.wax_us_per_frame / 10 / r.frame_ms.avg).toFixed(2)}% of the frame)${r.precise ? '' : '  [coarse clock]'}`);
    for (const s of sections) console.log(`  ${s.name.padEnd(10)} ${(s.us_per_frame).toFixed(1).padStart(8)} us/frame   worst ${s.max_ms.toFixed(2)} ms   (${s.calls} calls)`);
    for (const h of Array.isArray(r.worst) ? r.worst : []) console.log(`  long frame at ${h.at.toFixed(1)} s: ${h.frame_ms.toFixed(0)} ms, of which Wax ${h.wax_ms.toFixed(2)} ms`);
    process.exit(0);
  }
  case 'eval': {
    const file = option(args, '--file');
    const timeoutSec = Number(option(args, '--timeout', 20));
    flag(args, '--async'); // accepted and ignored: everything runs on the game thread now
    const code = file ? fs.readFileSync(file, 'utf8') : args.join(' ');
    result = await evalLua(code, { timeoutSec });
    break;
  }
  case 'log': {
    const lines = Number(args[0] ?? 60);
    console.log(fs.readFileSync(ue4ssLogPath(), 'utf8').split(/\r?\n/).slice(-lines).join('\n'));
    process.exit(0);
  }
  case 'stop':
    stop();
    result = { ok: true };
    break;
  case 'sync': {
    const reply = await sync();
    process.exit(reply.ok === false ? 1 : 0);
  }
  case 'watch':
    await watch();
    process.exit(0);
  default:
    console.error('usage: wax.mjs start [--windowed]|status|perf [--seconds n]|eval|log|stop|sync|watch');
    process.exit(2);
}
console.log(JSON.stringify(result, null, 2));
process.exit(result.ok === false ? 1 : 0);
