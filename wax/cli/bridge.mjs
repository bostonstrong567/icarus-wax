// Client side of the Wax bridge: send Lua to the running game and read the reply
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
export const RUN = path.join(ROOT, 'wax', 'runtime', 'run');
const DEFAULT_IN = path.join(RUN, 'in');
const DEFAULT_OUT = path.join(RUN, 'out');
const SLOTS = 8;
const GAME_EXE = 'Icarus-Win64-Shipping.exe';
const APP_ID = '1149460';

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function config() {
  return JSON.parse(fs.readFileSync(path.join(ROOT, 'wax', 'wax.config.json'), 'utf8'));
}

export function gameRunning() {
  const out = execFileSync('tasklist', ['/FI', `IMAGENAME eq ${GAME_EXE}`, '/NH'], { encoding: 'utf8' });
  return out.includes(GAME_EXE);
}

// Asks the game thread who it is. Null means it did not answer in time (not running, loading or hung).
export async function ping(timeoutSec = 3, { runtime } = {}) {
  const reply = await evalLua('return WaxStage0.info()', { timeoutSec, runtime });
  return reply.ok ? reply.values[0] : null;
}

export function crashFolders() {
  const dir = path.join(process.env.LOCALAPPDATA ?? '', 'Icarus', 'Saved', 'Crashes');
  try {
    return fs.readdirSync(dir).length;
  } catch {
    return 0;
  }
}

// runtime: the Wax folder of another install (the one holding Scripts and run); this workspace's when omitted.
export async function evalLua(code, { timeoutSec = 20, runtime } = {}) {
  const IN = runtime ? path.join(runtime, 'run', 'in') : DEFAULT_IN;
  const OUT = runtime ? path.join(runtime, 'run', 'out') : DEFAULT_OUT;
  fs.mkdirSync(IN, { recursive: true });
  fs.mkdirSync(OUT, { recursive: true });
  const id = randomBytes(6).toString('hex');
  const deadline = Date.now() + timeoutSec * 1000;

  // Claim a free request slot; several clients may be talking to the game at once.
  let slot = -1;
  let claim;
  while (slot === -1) {
    for (let i = 0; i < SLOTS && slot === -1; i++) {
      const candidate = path.join(IN, `${i}.claim`);
      try {
        // A claim older than 60s was left by a client that died.
        if (fs.existsSync(candidate) && Date.now() - fs.statSync(candidate).mtimeMs > 60_000) fs.rmSync(candidate, { force: true });
        fs.closeSync(fs.openSync(candidate, 'wx'));
        slot = i;
        claim = candidate;
      } catch {}
    }
    if (slot === -1) {
      if (Date.now() > deadline) return { ok: false, error: 'timeout: no free request slot' };
      await sleep(10);
    }
  }

  const request = path.join(IN, `${slot}.lua`);
  const reply = path.join(OUT, `${id}.json`);
  try {
    fs.writeFileSync(request + '.part', `--id:${id}\n${code}`);
    fs.renameSync(request + '.part', request);
    // The game looks for this one file; it scans the slots only when it is there.
    fs.writeFileSync(path.join(IN, 'wake'), '');
    // Hold the slot until the game has picked the request up.
    while (fs.existsSync(request)) {
      if (Date.now() > deadline) {
        fs.rmSync(request, { force: true });
        return { ok: false, error: gameRunning() ? 'timeout: the game did not pick up the request (game thread not ticking?)' : 'the game is not running' };
      }
      await sleep(5);
    }
    fs.rmSync(claim, { force: true });
    claim = null;
    while (!fs.existsSync(reply)) {
      if (Date.now() > deadline) {
        return { ok: false, error: gameRunning() ? 'timeout: no reply (the code may still be running, or is blocked)' : 'the game exited (crash?) while running this code' };
      }
      await sleep(5);
    }
    const text = fs.readFileSync(reply, 'utf8');
    fs.rmSync(reply, { force: true });
    return JSON.parse(text);
  } finally {
    if (claim) fs.rmSync(claim, { force: true });
  }
}

// Starts the game through Steam and waits for the bridge. windowed: a 1280x720 window instead of the user's settings.
export async function start({ timeoutSec = 240, windowed = false } = {}) {
  if (gameRunning()) {
    const info = await ping();
    if (info) return { ok: true, already: true, ...info };
  } else {
    // A crash leaves Unreal's reporter dialog open; it has no value here.
    try { execFileSync('taskkill', ['/IM', 'CrashReportClient.exe', '/F'], { stdio: 'ignore' }); } catch {}
    const { steamExe } = config();
    const args = ['-applaunch', APP_ID];
    if (windowed) args.push('-windowed', '-ResX=1280', '-ResY=720');
    spawn(steamExe, args, { detached: true, stdio: 'ignore' }).unref();
  }
  const deadline = Date.now() + timeoutSec * 1000;
  while (Date.now() < deadline) {
    const info = await ping(2);
    if (info) return { ok: true, ...info };
    await sleep(500);
  }
  return { ok: false, error: `bridge not ready after ${timeoutSec}s`, gameRunning: gameRunning() };
}

export function stop() {
  if (gameRunning()) execFileSync('taskkill', ['/IM', GAME_EXE, '/F']);
}

export function ue4ssLogPath() {
  return path.join(config().win64, 'ue4ss', 'UE4SS.log');
}
