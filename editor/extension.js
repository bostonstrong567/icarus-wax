'use strict';
// Wax for Icarus: wires the features in lib/features to VS Code
const vscode = require('vscode');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const paths = require('./lib/paths');
const modsLib = require('./lib/mods');
const { Game, loadBridge } = require('./lib/game');
const { Tracker } = require('./lib/problems');

const FEATURES = [
  require('./lib/features/locate'),
  require('./lib/features/docs'),
  require('./lib/features/editor'),
  require('./lib/features/create'),
  require('./lib/features/requires'),
  require('./lib/features/run'),
  require('./lib/features/log'),
  require('./lib/features/view'),
];

let app = null;

function createApp(context) {
  let bridge = null;
  const created = {
    vscode,
    context,
    extensionDir: context.extensionPath,
    output: vscode.window.createOutputChannel('Wax', 'log'),
    events: new EventEmitter(),
    tracker: new Tracker(),
    game: new Game({ bridge: () => (bridge ??= loadBridge(context.extensionPath)) }),
    folders: [],
    runtime: null,
    found: { dir: null, source: null, game: null, problem: null },
    modsDir: null,
    scanned: null,
    scannedAt: 0,
  };
  context.subscriptions.push(created.output);

  // Looks for the game's Wax folder in the settings, the open folders and Steam, and changes nothing.
  created.look = () => {
    const folders = (vscode.workspace.workspaceFolders ?? [])
      .filter((folder) => folder.uri.scheme === 'file').map((folder) => folder.uri.fsPath);
    const settings = vscode.workspace.getConfiguration('wax');
    const found = paths.findRuntime({
      runtimePath: settings.get('runtimePath', ''), gamePath: settings.get('gamePath', ''), folders,
      steam: () => paths.findSteamGames(),
    });
    return { folders, found };
  };

  // Works out where the Wax folder and the mods are. Called again when settings or folders change. quiet: say nothing.
  created.locate = ({ quiet = false } = {}) => {
    const { folders, found } = created.look();
    created.folders = folders;
    created.found = found;
    created.runtime = found.dir;
    created.modsDir = paths.findModsDir({ folders, runtime: found.dir });
    created.scanned = null;
    vscode.commands.executeCommand('setContext', 'wax.hasRuntime', Boolean(found.dir));
    created.game.setRuntime(found.dir);
    created.events.emit('located', { quiet });
  };

  // The mods on disk. Scanned again after a file event, and at most every two seconds otherwise.
  created.mods = () => {
    if (!created.scanned || Date.now() - created.scannedAt > 2000) {
      created.scanned = modsLib.scanMods(created.modsDir);
      created.scannedAt = Date.now();
    }
    return created.scanned;
  };

  // Which mod a file belongs to: { mod, relative }, or null.
  created.modOf = (file) => {
    const found = modsLib.modOf(file, created.mods());
    if (found) return found;
    // a mod the game loads from somewhere else
    const elsewhere = modsLib.modOf(file, created.game.mods.filter((mod) => mod.dir));
    const described = elsewhere && modsLib.describeMod(elsewhere.mod.id, elsewhere.mod.dir);
    return described ? { mod: described, relative: elsewhere.relative } : null;
  };

  // Every mod worth showing: what the game reports, then the folders it has not picked up.
  created.listMods = () => {
    const onDisk = new Map(created.mods().map((mod) => [mod.id, mod]));
    const connected = created.game.connected;
    const list = [];
    for (const mod of connected ? created.game.mods : []) {
      const here = onDisk.get(mod.id);
      onDisk.delete(mod.id);
      list.push({
        id: mod.id, name: mod.name || (here && here.name) || mod.id, version: mod.version ?? (here && here.version) ?? null,
        status: mod.status, enabled: mod.enabled !== false, error: mod.error ?? null, fresh: Boolean(mod.fresh),
        loadMs: mod.loadMs ?? null, dir: (here && here.dir) || mod.dir || null, main: (here && here.main) || 'init.lua', inGame: true,
        description: (here && here.description) || null,
      });
    }
    for (const mod of onDisk.values()) {
      list.push({
        id: mod.id, name: mod.name, version: mod.version, status: connected ? 'not found by the game' : 'on disk',
        enabled: true, error: null, fresh: false, loadMs: null, dir: mod.dir, main: mod.main, inGame: false,
        description: mod.description || null,
      });
    }
    return list;
  };

  // The mod a command is about: the one clicked in the view, the one the file belongs to, or one the user picks.
  created.pickMod = async (arg, title) => {
    const all = created.listMods();
    if (arg && typeof arg.id === 'string') return all.find((mod) => mod.id === arg.id) ?? arg;
    const editor = vscode.window.activeTextEditor;
    const file = arg && typeof arg.fsPath === 'string' ? arg.fsPath
      : editor && editor.document.uri.scheme === 'file' ? editor.document.uri.fsPath : null;
    const found = file ? created.modOf(file) : null;
    if (found) return all.find((mod) => mod.id === found.mod.id) ?? found.mod;
    if (!all.length) {
      vscode.window.showInformationMessage('Wax: there are no mods yet. Make one with "Wax: New Mod".');
      return null;
    }
    const picked = await vscode.window.showQuickPick(
      all.map((mod) => ({ label: mod.name, description: mod.name === mod.id ? mod.status : `${mod.id}, ${mod.status}`, mod })),
      { title, placeHolder: 'Pick a mod' });
    return picked ? picked.mod : null;
  };

  // Looks again when the Wax folder is not known, because Wax may have been installed since. True when it is known now.
  created.lookAgain = () => {
    if (!created.runtime && created.look().found.dir) created.locate({ quiet: true });
    return Boolean(created.runtime);
  };

  // False, after telling the user, when the game's Wax folder is not known.
  created.needRuntime = () => {
    if (created.lookAgain()) return true;
    created.askForGame();
    return false;
  };

  created.command = (id, handler) => {
    context.subscriptions.push(vscode.commands.registerCommand(id, async (...args) => {
      try {
        return await handler(...args);
      } catch (error) {
        vscode.window.showErrorMessage(`Wax: ${error && error.message ? error.message : error}`);
        return undefined;
      }
    }));
  };

  return created;
}

// Tells the features when a mod file appears, goes away, or a manifest changes.
function watchMods(target) {
  let watcher = null;
  let timer = null;
  const changed = () => {
    target.scanned = null;
    clearTimeout(timer);
    timer = setTimeout(() => target.events.emit('changed'), 200);
  };
  const rewatch = () => {
    if (watcher) watcher.dispose();
    watcher = null;
    if (!target.modsDir) return;
    watcher = vscode.workspace.createFileSystemWatcher(new vscode.RelativePattern(target.modsDir, '**/*.lua'));
    watcher.onDidCreate(changed);
    watcher.onDidDelete(changed);
    watcher.onDidChange((uri) => {
      if (path.basename(uri.fsPath) === 'mod.lua') changed();
    });
  };
  target.events.on('located', rewatch);
  target.context.subscriptions.push({
    dispose: () => {
      clearTimeout(timer);
      if (watcher) watcher.dispose();
    },
  });
}

function activate(context) {
  const created = createApp(context);
  app = created;
  for (const feature of FEATURES) feature.register(created);
  watchMods(created);
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration('wax.runtimePath') || event.affectsConfiguration('wax.gamePath')) created.locate();
    }),
    vscode.workspace.onDidChangeWorkspaceFolders(() => created.locate()),
    vscode.window.onDidChangeWindowState((state) => {
      if (state.focused) created.lookAgain();
    }),
    { dispose: () => created.game.stop() },
  );
  created.locate();
  created.game.start();
  return created;
}

function deactivate() {
  if (app) app.game.stop();
  app = null;
}

module.exports = { activate, deactivate };
