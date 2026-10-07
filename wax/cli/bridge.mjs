// Client side of the Wax bridge: send a command, or in developer mode Lua, to the running game and read the reply
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
export const RUNTIME = path.join(ROOT, 'wax', 'runtime');
export const RUN = path.join(RUNTIME, 'run');
const SLOTS = 8;
const GAME_EXE = 'Icarus-Win64-Shipping.exe';
const APP_ID = '1149460';
// The system and the administrators, by the ids Windows gives them in every language.
const SYSTEM_SID = 'S-1-5-18';
const ADMINISTRATORS_SID = 'S-1-5-32-544';

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// A program of Windows by its full path, so that nothing with the same name in another folder is started.
const windowsTool = (name) => path.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', name);

export function config() {
  return JSON.parse(fs.readFileSync(path.join(ROOT, 'wax', 'wax.config.json'), 'utf8'));
}

export function gameRunning() {
  const out = execFileSync(windowsTool('tasklist.exe'), ['/FI', `IMAGENAME eq ${GAME_EXE}`, '/NH'], { encoding: 'utf8', windowsHide: true });
  return out.includes(GAME_EXE);
}

let ownSid = null;

// Leaves a folder to the current user, the system and the administrators. Returns what went wrong, or null.
export function limitToUser(dir) {
  if (process.platform !== 'win32') return null;
  try {
    if (!ownSid) {
      const who = execFileSync(windowsTool('whoami.exe'), ['/user', '/fo', 'csv', '/nh'], { encoding: 'utf8', windowsHide: true, timeout: 10000 });
      ownSid = /"(S-1-[0-9-]+)"/.exec(who)?.[1] ?? null;
    }
    if (!ownSid) return 'Windows did not say which account this is';
    const grants = [ownSid, SYSTEM_SID, ADMINISTRATORS_SID].map((sid) => `*${sid}:(OI)(CI)F`);
    execFileSync(windowsTool('icacls.exe'), [dir, '/inheritance:r', '/grant:r', ...grants], { stdio: 'ignore', windowsHide: true, timeout: 10000 });
    return null;
  } catch (error) {
    return String(error && error.message ? error.message : error).split(/\r?\n/)[0];
  }
}

// The folders requests and replies go through. One that has to be made is limited to the current user before anything is put in it.
function runFolders(runtime, warn) {
  const run = path.join(runtime ?? RUNTIME, 'run');
  const folders = { IN: path.join(run, 'in'), OUT: path.join(run, 'out') };
  for (const dir of [run, folders.IN, folders.OUT]) {
    if (fs.existsSync(dir)) continue;
    fs.mkdirSync(dir, { recursive: true });
    const problem = limitToUser(dir);
    if (problem) warn(`Wax: ${dir} could not be limited to your Windows account (${problem}). Other accounts on this PC may be able to write there.`);
  }
  return folders;
}

// Asks the game thread who it is: { frame, uptime, requests, core, dev }. Null means it did not answer in time (not running, loading or hung).
export async function ping(timeoutSec = 3, { runtime } = {}) {
  const reply = await command('ping', {}, { timeoutSec, runtime });
  if (!reply.ok) return null;
  if (reply.values && reply.values[0]) return reply.values[0];
  // a Wax from before commands takes the request for Lua that says nothing, and runs Lua for anyone
  const old = await evalLua('return WaxStage0.info()', { timeoutSec, runtime });
  return old.ok && old.values ? old.values[0] ?? null : null;
}

export function crashFolders() {
  const dir = path.join(process.env.LOCALAPPDATA ?? '', 'Icarus', 'Saved', 'Crashes');
  try {
    return fs.readdirSync(dir).length;
  } catch {
    return 0;
  }
}

// What to tell someone whose Lua the game refused (the reply's code is "dev-off").
export function devModeHelp(runtime) {
  return `Developer mode is off for the Wax in ${runtime ?? RUNTIME}, so the game did not run this. `
    + 'To switch it on, put a file named dev.txt in that folder, beside Scripts (in VS Code: "Wax: Switch Developer Mode On"). '
    + 'While it is on, any program on this PC can run Lua in the game, and Wax does not update itself.';
}

// Puts one request in a free slot and waits for the reply. runtime: the Wax folder of another install (the one holding Scripts and run); this workspace's when omitted.
async function send(text, { timeoutSec = 20, runtime, warn = (message) => console.warn(message) } = {}) {
  const { IN, OUT } = runFolders(runtime, warn);
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
    fs.writeFileSync(request + '.part', `--id:${id}\n${text}`);
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
    const answer = fs.readFileSync(reply, 'utf8');
    fs.rmSync(reply, { force: true });
    return JSON.parse(answer);
  } finally {
    if (claim) fs.rmSync(claim, { force: true });
  }
}

// Runs Lua in the game. The game only does that in developer mode: otherwise the reply is { ok: false, code: "dev-off", error }.
export function evalLua(code, options) {
  return send(code, options);
}

// One of the things the game does for anyone: "ping", or "mod-added" with { id }. The reply is { ok, values: [what it says] } or { ok: false, code, error }.
export function command(name, values = {}, options) {
  if (!/^[a-z][a-z-]*$/.test(name)) throw new Error(`"${name}" is not the name of a command`);
  const lines = [`--wax:${name}`];
  for (const [key, value] of Object.entries(values)) {
    if (!/^[a-z]+$/.test(key) || /[\r\n]/.test(String(value))) throw new Error(`"${key}" cannot be sent with a command`);
    lines.push(`${key}=${value}`);
  }
  return send(lines.join('\n') + '\n', options);
}

// Why the Steam program named in wax.config.json is not started, or null when it can be.
export function steamProblem(steamExe) {
  if (typeof steamExe !== 'string' || !steamExe.trim()) return 'wax.config.json names no steamExe';
  const named = `steamExe in wax.config.json is "${steamExe}"`;
  if (path.win32.basename(steamExe).toLowerCase() !== 'steam.exe') return `${named}, which is not a file named steam.exe`;
  if (!path.isAbsolute(steamExe)) return `${named}, which is not a full path`;
  let found;
  try {
    found = fs.statSync(steamExe);
  } catch {
    return `${named}, and there is no such file`;
  }
  return found.isFile() ? null : `${named}, which is not a file`;
}

// Starts the game through Steam and waits for the bridge. windowed: a 1280x720 window instead of the user's settings.
export async function start({ timeoutSec = 240, windowed = false } = {}) {
  if (gameRunning()) {
    const info = await ping();
    if (info) return { ok: true, already: true, ...info };
  } else {
    const { steamExe } = config();
    const problem = steamProblem(steamExe);
    if (problem) return { ok: false, error: `Steam was not started: ${problem}.` };
    // A crash leaves Unreal's reporter dialog open; it has no value here.
    try { execFileSync(windowsTool('taskkill.exe'), ['/IM', 'CrashReportClient.exe', '/F'], { stdio: 'ignore' }); } catch {}
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
  if (gameRunning()) execFileSync(windowsTool('taskkill.exe'), ['/IM', GAME_EXE, '/F']);
}

export function ue4ssLogPath() {
  return path.join(config().win64, 'ue4ss', 'UE4SS.log');
}
