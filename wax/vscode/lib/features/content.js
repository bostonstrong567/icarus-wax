'use strict';
// Game content of a mod: cook the assets, put the pak in the mod, and build again by itself when an asset is saved
const fs = require('node:fs');
const path = require('node:path');

const ASSETS = ['unreal', 'Icarus', 'Content', 'Mods'];
const TOOL = ['wax', 'cli', 'content.mjs'];
const COOK = ['scripts', 'Cook-UnrealProject.ps1'];
const OPEN = ['scripts', 'Open-UnrealProject.ps1'];
const QUIET_MS = 4000;
const NEEDS = 'Building game content needs the Wax source folder open, with its Unreal editor. This folder has no wax/cli/content.mjs.';

function register(app) {
  const { vscode } = app;
  let terminal = null;
  let watcher = null;
  const timers = new Map();

  // The open folder that holds the tools, or null.
  const workspace = () => {
    for (const folder of vscode.workspace.workspaceFolders ?? []) {
      const root = folder.uri.fsPath;
      if (fs.existsSync(path.join(root, ...TOOL)) && fs.existsSync(path.join(root, ...COOK))) return root;
    }
    return null;
  };

  const needWorkspace = () => {
    const root = workspace();
    if (!root) vscode.window.showWarningMessage(`Wax: ${NEEDS}`);
    return root;
  };

  const run = (root, line, show) => {
    if (!terminal || terminal.exitStatus !== undefined) terminal = vscode.window.createTerminal({ name: 'Wax content', cwd: root });
    if (show) terminal.show(true);
    terminal.sendText(line, true);
  };

  const build = (root, id, show) => run(root, `node wax/cli/content.mjs build ${id}`, show);

  app.command('wax.buildContent', async (arg) => {
    const root = needWorkspace();
    if (!root) return;
    const mod = await app.pickMod(arg, 'Build the game content of which mod?');
    if (!mod) return;
    if (!fs.existsSync(path.join(root, ...ASSETS, mod.id))) {
      const make = 'Make the Folder';
      const choice = await vscode.window.showInformationMessage(
        `Wax: ${mod.id} has no assets yet. They go in unreal/Icarus/Content/Mods/${mod.id}, which the game sees as /Game/Mods/${mod.id}.`, make);
      if (choice !== make) return;
      run(root, `node wax/cli/content.mjs new ${mod.id}`, true);
      return;
    }
    build(root, mod.id, true);
  });

  app.command('wax.openUnreal', async () => {
    const root = needWorkspace();
    if (!root) return;
    run(root, `pwsh -NoProfile -File ${OPEN.join('/')}`, true);
  });

  // Auto build: an asset saved in the editor builds the content of its mod, and the game takes the new pak.
  const rewatch = () => {
    if (watcher) watcher.dispose();
    watcher = null;
    for (const timer of timers.values()) clearTimeout(timer);
    timers.clear();
    if (!vscode.workspace.getConfiguration('wax').get('content.autoBuild', false)) return;
    const root = workspace();
    if (!root) return;
    const assets = path.join(root, ...ASSETS);
    if (!fs.existsSync(assets)) return;
    watcher = vscode.workspace.createFileSystemWatcher(new vscode.RelativePattern(assets, '**/*.{uasset,umap}'));
    const changed = (uri) => {
      const id = path.relative(assets, uri.fsPath).split(path.sep)[0];
      if (!/^[A-Za-z][A-Za-z0-9_]*$/.test(id)) return;
      clearTimeout(timers.get(id));
      timers.set(id, setTimeout(() => {
        timers.delete(id);
        vscode.window.setStatusBarMessage(`$(sync) Wax: building the game content of ${id}`, 8000);
        build(root, id, false);
      }, QUIET_MS));
    };
    watcher.onDidCreate(changed);
    watcher.onDidChange(changed);
    watcher.onDidDelete(changed);
  };

  app.context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration('wax.content.autoBuild')) rewatch();
    }),
    vscode.workspace.onDidChangeWorkspaceFolders(rewatch),
    { dispose: () => { if (watcher) watcher.dispose(); for (const timer of timers.values()) clearTimeout(timer); } },
  );
  rewatch();
}

module.exports = { register };
