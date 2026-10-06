// Soak test for the bridge: many requests mixing memory churn, fresh coroutines and engine calls, with every
// reply checked against a value computed independently here. A corrupted Lua state shows up as a wrong
// checksum, a lost reply, a Lua-side error, or a crash folder.
//   node wax/tests/live/soak.mjs [rounds=20000] [workers=4]
import fs from 'node:fs';
import { ping, crashFolders, evalLua, gameRunning, ue4ssLogPath } from '../../cli/bridge.mjs';

const ROUNDS = Number(process.argv[2] ?? 20000);
const WORKERS = Number(process.argv[3] ?? 4);

function luaFor(seed) {
  return `
local seed = ${seed}
local parts, sum = {}, 0
for i = 1, 400 do
    local s = string.rep(string.char(65 + (seed + i) % 26), 8 + i % 16)
    parts[i] = { s = s, n = i * seed % 9973 }
    sum = sum + #s + parts[i].n
end
local joined = {}
for i = 1, 400 do joined[i] = parts[i].s end
sum = sum + #table.concat(joined)

local cosum = 0
for c = 1, 20 do
    local co = coroutine.wrap(function(a)
        local x = a
        for _ = 1, 5 do x = x + coroutine.yield(x * 2) end
        return x
    end)
    local v = co(c + seed % 7)
    for i = 1, 5 do v = co(i) end
    cosum = cosum + v
end

local pc = FindFirstOf("PlayerController")
local world = FindFirstOf("World")
local out = {
    seed = seed, sum = sum, cosum = cosum,
    pc = pc:IsValid() and pc:GetFullName() or "invalid",
    world = world:IsValid() and world:GetFullName() or "invalid",
    cls = pc:IsValid() and pc:GetClass():GetFullName() or "invalid",
    gameThread = IsInGameThread(),
}
if seed % 250 == 0 then
    local actors = FindAllOf("Actor")
    out.actors = actors and #actors or 0
end
collectgarbage("step", 200)
return out`;
}

function expected(seed) {
  let sum = 0;
  let total = 0;
  for (let i = 1; i <= 400; i++) {
    const len = 8 + (i % 16);
    sum += len + ((i * seed) % 9973);
    total += len;
  }
  // Each coroutine returns its start value plus 1+2+3+4+5.
  return { sum: sum + total, cosum: 210 + 20 * (seed % 7) + 300 };
}

const log = ue4ssLogPath();
const logBefore = fs.readFileSync(log, 'utf8').length;
const crashesBefore = crashFolders();
const startedAt = Date.now();

const latencies = [];
const problems = [];
let next = 1;
let done = 0;
let stable = null;

async function worker() {
  while (next <= ROUNDS && problems.length < 20) {
    const seed = next++;
    const t0 = performance.now();
    const reply = await evalLua(luaFor(seed), { timeoutSec: 60 });
    latencies.push(performance.now() - t0);
    done++;
    if (!reply.ok) {
      problems.push({ seed, kind: 'error', detail: String(reply.error).slice(0, 300) });
      if (!gameRunning()) break;
      continue;
    }
    const v = reply.values[0];
    const want = expected(seed);
    if (v.seed !== seed || v.sum !== want.sum || v.cosum !== want.cosum) {
      problems.push({ seed, kind: 'wrong value', got: { seed: v.seed, sum: v.sum, cosum: v.cosum }, want });
    }
    if (v.gameThread !== true) problems.push({ seed, kind: 'not on the game thread' });
    // The player controller and world must not change identity mid-run (no map change is expected).
    stable ??= { pc: v.pc, world: v.world, cls: v.cls };
    if (v.pc !== stable.pc || v.world !== stable.world || v.cls !== stable.cls) {
      problems.push({ seed, kind: 'engine value changed', got: { pc: v.pc, world: v.world }, first: stable });
    }
    if (seed % 250 === 0 && !(v.actors > 0)) problems.push({ seed, kind: 'no actors found', actors: v.actors });
    if (done % 2000 === 0) console.error(`${done}/${ROUNDS} rounds, ${problems.length} problem(s)`);
  }
}

await Promise.all(Array.from({ length: WORKERS }, worker));

const newLog = fs.readFileSync(log, 'utf8').slice(logBefore);
latencies.sort((a, b) => a - b);
const pct = (p) => Math.round(latencies[Math.min(latencies.length - 1, Math.floor(latencies.length * p))] * 10) / 10;
const seconds = (Date.now() - startedAt) / 1000;
const result = {
  rounds: done,
  requested: ROUNDS,
  workers: WORKERS,
  seconds: Math.round(seconds),
  perSecond: Math.round(done / seconds),
  latencyMs: { p50: pct(0.5), p95: pct(0.95), p99: pct(0.99), max: pct(1) },
  problems,
  newCrashFolders: crashFolders() - crashesBefore,
  luaRefErrorsInLog: (newLog.match(/Ref was not function/g) ?? []).length,
  errorLinesInLog: newLog.split(/\r?\n/).filter((line) => /error|LUA_ERR/i.test(line)).slice(0, 5),
  gameStillRunning: gameRunning(),
  gameThreadTicking: Boolean(await ping()),
  world: stable?.world,
  playerController: stable?.cls,
};
result.pass = done === ROUNDS && problems.length === 0 && result.newCrashFolders === 0 && result.luaRefErrorsInLog === 0 && result.gameStillRunning && result.gameThreadTicking;
console.log(JSON.stringify(result, null, 2));
process.exit(result.pass ? 0 : 1);
