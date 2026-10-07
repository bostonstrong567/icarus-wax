'use strict';
// The running game, as the extension sees it: is it there, what has it logged, which mods does it have
const fs = require('node:fs');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const { execFile } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const chunks = require('./chunks');
const { firstLine } = require('./logformat');

const GAME_EXE = 'Icarus-Win64-Shipping.exe';

function isGameRunning() {
  if (process.platform !== 'win32') return Promise.resolve(false);
  // by its full path, so that no other program named tasklist is started
  const tasklist = path.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'tasklist.exe');
  return new Promise((resolve) => {
    execFile(tasklist, ['/FI', `IMAGENAME eq ${GAME_EXE}`, '/NH'], { windowsHide: true, timeout: 5000 },
      (error, stdout) => resolve(!error && String(stdout).includes(GAME_EXE)));
  });
}

// The bridge client: the workspace's own inside a source checkout (wax\vscode beside wax\cli and wax\runtime), otherwise the copy packed into the extension.
function loadBridge(extensionDir) {
  const own = path.join(extensionDir, '..', 'cli', 'bridge.mjs');
  const checkout = fs.existsSync(own) && fs.existsSync(path.join(extensionDir, '..', 'runtime', 'Scripts', 'main.lua'));
  const file = checkout ? own : path.join(extensionDir, 'bundled', 'bridge.mjs');
  if (!fs.existsSync(file)) return Promise.reject(new Error('bridge.mjs is missing from the extension (bundled\\bridge.mjs).'));
  return import(pathToFileURL(file).href);
}

// The game's replies turn an empty list into {}.
const asArray = (value) => (Array.isArray(value) ? value : []);

const signature = (mods) => JSON.stringify(mods.map((mod) =>
  [mod.id, mod.name, mod.version, mod.status, mod.enabled, mod.error, mod.generation, mod.fresh, mod.dir]));

// What the game answers to Lua while developer mode is off.
const DEV_OFF = 'dev-off';

// state: "unset" (no runtime folder), "absent" (no game), "busy" (not answering), "nocore" (bridge without the core), "devoff" (it answers, and runs no Lua while developer mode is off), "connected"
class Game extends EventEmitter {
  constructor({ runtime = null, bridge, running = isGameRunning, interval = 1000, backlog = 40 }) {
    super();
    this.runtime = runtime;
    this.loadBridge = bridge;
    this.running = running;
    this.interval = interval;
    this.backlog = backlog;
    this.state = runtime ? 'absent' : 'unset';
    this.mods = [];
    this.active = false;
    this.timer = null;
    this.polling = null;
    this.lastProblem = null;
    this.forget();
  }

  get connected() {
    return this.state === 'connected';
  }

  forget() {
    this.core = '';
    this.lastId = -1;
    this.lastCount = 0;
  }

  setRuntime(runtime) {
    if (runtime === this.runtime) return;
    this.runtime = runtime;
    this.forget();
    this.setMods([]);
    this.setState(runtime ? 'absent' : 'unset');
    if (this.active) this.schedule(0);
  }

  start() {
    this.active = true;
    this.schedule(0);
  }

  stop() {
    this.active = false;
    clearTimeout(this.timer);
    this.timer = null;
  }

  schedule(ms) {
    clearTimeout(this.timer);
    this.timer = null;
    if (this.active && this.runtime) this.timer = setTimeout(() => this.tick(), ms);
  }

  setState(state) {
    if (state === this.state) return;
    const previous = this.state;
    this.state = state;
    if (state !== 'connected') this.setMods([]);
    this.emit('state', state, previous);
  }

  setMods(mods) {
    const changed = signature(mods) !== signature(this.mods);
    this.mods = mods;
    if (changed) this.emit('mods', mods);
  }

  // Runs one of the files in lua/ in the game and returns what it returned. Throws with the game's own message, and its code when it gives one.
  async call(name, args = [], { timeoutSec = 10 } = {}) {
    if (!this.runtime) throw new Error('The Wax folder of the game was not found.');
    const bridge = await this.loadBridge();
    const warn = (text) => this.emit('problem', new Error(text));
    const reply = await bridge.evalLua(chunks.call(name, ...args), { timeoutSec, runtime: this.runtime, warn });
    if (!reply.ok) {
      const error = new Error(firstLine(reply.error) || 'the game did not answer');
      if (reply.code) error.code = reply.code;
      throw error;
    }
    const value = asArray(reply.values)[0];
    return value === '<nil>' ? undefined : value;
  }

  // While developer mode is off the game is asked with a command, so no Lua is sent that it would refuse again. True when it is still off.
  async stillOff(timeoutSec) {
    const bridge = await this.loadBridge();
    if (typeof bridge.ping !== 'function') return false;
    const info = await bridge.ping(timeoutSec, { runtime: this.runtime });
    if (!info) throw new Error('the game stopped answering');
    return info.dev === false;
  }

  // One look at the game. False when it did not answer.
  poll(timeoutSec = 3) {
    if (!this.polling) this.polling = this.look(timeoutSec).finally(() => { this.polling = null; });
    return this.polling;
  }

  // A look that starts after this call: one already under way may be from before what the caller just did.
  async pollAgain() {
    if (this.polling) await this.polling;
    return this.poll();
  }

  async look(timeoutSec) {
    let reply;
    try {
      if (this.state === 'devoff' && (await this.stillOff(timeoutSec))) return true;
      reply = await this.call('poll', [this.core, this.lastId, this.lastCount, this.backlog], { timeoutSec });
    } catch (error) {
      if (error.code === DEV_OFF) {
        // the game is there and answered: it is not a problem, and not a connection either
        this.lastProblem = null;
        this.forget();
        this.setState('devoff');
        return true;
      }
      // said once per outage, so a game that is loading does not fill the log
      if (error.message !== this.lastProblem) this.emit('problem', error);
      this.lastProblem = error.message;
      return false;
    }
    this.lastProblem = null;
    if (!reply || !reply.core) {
      this.forget();
      this.setState('nocore');
      return true;
    }
    const entries = asArray(reply.entries);
    this.core = reply.core;
    this.lastId = reply.newest;
    if (entries.length) this.lastCount = entries[entries.length - 1].count;
    this.setState('connected');
    if (entries.length) this.emit('log', entries);
    this.setMods(asArray(reply.mods));
    return true;
  }

  async tick() {
    if (!this.active || !this.runtime) return;
    let wait = this.interval;
    try {
      const wasAnswering = this.state === 'connected' || this.state === 'nocore' || this.state === 'devoff';
      if (!wasAnswering && !(await this.running())) {
        this.setState('absent');
        wait = 5000;
      } else if (!(await this.poll(wasAnswering ? 3 : 2))) {
        const running = wasAnswering ? await this.running() : true;
        this.setState(running ? 'busy' : 'absent');
        wait = running ? 3000 : 5000;
      } else if (this.state === 'nocore' || this.state === 'devoff') {
        wait = 3000;
      }
    } catch (error) {
      if (error.message !== this.lastProblem) this.emit('problem', error);
      this.lastProblem = error.message;
      wait = 5000;
    }
    this.schedule(wait);
  }

  // For things the user asked for: fails at once, in plain words, when the game is not there.
  async ask(name, args, options) {
    if (!this.connected && !(await this.running())) throw new Error('ICARUS is not running.');
    return this.call(name, args, options);
  }

  async refresh() {
    await this.ask('mods', ['sync']);
    return this.pollAgain();
  }

  async reload(id) {
    await this.ask('mods', ['reload', id]);
    return this.pollAgain();
  }

  async setEnabled(id, enabled) {
    await this.ask('mods', [enabled ? 'enable' : 'disable', id]);
    return this.pollAgain();
  }

  // source: the Lua. chunkname: how errors name it. modId: the mod it belongs to, if any.
  async run({ source, chunkname, modId = null, fresh = false, expression = false }) {
    const result = await this.ask('run', [source, chunkname, modId, fresh, expression], { timeoutSec: 30 });
    await this.pollAgain();
    return { ...result, values: asArray(result && result.values) };
  }

  async stopScripts() {
    const removed = await this.ask('stop', []);
    await this.pollAgain();
    return removed ?? 0;
  }
}

module.exports = { Game, isGameRunning, loadBridge, asArray, GAME_EXE };
