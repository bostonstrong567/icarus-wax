// Drives co_4_stress.lua: many batches of coroutine create/finish cycles, watching process memory from outside.
//   node wax/tests/live/co_4_stress.mjs [batches=20]
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { ping, crashFolders, evalLua, gameRunning } from '../../cli/bridge.mjs';

const BATCHES = Number(process.argv[2] ?? 20);
const code = fs.readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), 'co_4_stress.lua'), 'utf8');

function privateMB() {
  const out = execFileSync('powershell', ['-NoProfile', '-Command',
    "(Get-Process 'Icarus-Win64-Shipping').PrivateMemorySize64 / 1MB"], { encoding: 'utf8' });
  return Math.round(Number(out.trim()));
}

const crashesBefore = crashFolders();
const memBefore = privateMB();
const rows = [];
let failed = null;
for (let i = 0; i < BATCHES; i++) {
  const reply = await evalLua(code, { timeoutSec: 60 });
  if (!reply.ok) { failed = reply.error; break; }
  const v = reply.values[0];
  rows.push({ ...v, privateMB: privateMB() });
  if (!v.sumOk || v.crossFrameBad > 0) { failed = `wrong result in batch ${v.batch}: ${JSON.stringify(v)}`; break; }
}
const last = rows[rows.length - 1] ?? {};
const micros = rows.map((r) => r.microsPerCycle).sort((a, b) => a - b);
const result = {
  batches: rows.length,
  coroutinesCreated: last.created,
  microsPerCreateResumeResume: { min: micros[0]?.toFixed(2), median: micros[Math.floor(micros.length / 2)]?.toFixed(2), max: micros[micros.length - 1]?.toFixed(2) },
  luaKB: { first: Math.round(rows[0]?.luaKB), last: Math.round(last.luaKB) },
  processPrivateMB: { before: memBefore, afterFirstBatch: rows[0]?.privateMB, afterLastBatch: last.privateMB },
  crossFrameResumes: { ok: last.crossFrameOk, bad: last.crossFrameBad },
  failed,
  newCrashFolders: crashFolders() - crashesBefore,
  gameStillRunning: gameRunning(),
  gameThreadTicking: Boolean(await ping()),
};
result.pass = !failed && rows.length === BATCHES && result.newCrashFolders === 0 && result.gameStillRunning && result.gameThreadTicking;
console.log(JSON.stringify(result, null, 2));
process.exit(result.pass ? 0 : 1);
