'use strict';
// Game content of a mod: cook the assets, put the pak in the mod, and build again by itself when an asset is saved
const fs = require('node:fs');
const path = require('node:path');

const ASSETS = ['unreal', 'Icarus', 'Content', 'Mods'];
const TOOL = ['wax', 'cli', 'content.mjs'];
const COOK = ['scripts', 'Cook-UnrealProject.ps1'];
const OPEN = ['scripts', 'Open-UnrealProject.ps1'];
const INSTALL = ['scripts', 'Install-UnrealEditor.ps1'];
const EDITOR = ['Engine', 'Binaries', 'Win64', 'UE4Editor-Cmd.exe'];
const CHOOSE = 'Choose Its Folder';
const GET = 'Install It';
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

  // The folder of the Unreal Editor 4.27 to cook with: the one in the settings, else the one in the open folder. null when neither is there.
  const editorFolder = (root) => {
    const chosen = String(vscode.workspace.getConfiguration('wax').get('unrealPath', '') || '').trim();
    if (chosen && fs.existsSync(path.join(chosen, ...EDITOR))) return chosen;
    const own = path.join(root, 'engine', 'UE_4.27');
    return fs.existsSync(path.join(own, ...EDITOR)) ? own : null;
  };

  // False, after offering the two ways to get one, when there is no editor to cook with.
  const needEditor = async (root) => {
    if (editorFolder(root)) return true;
    const choice = await vscode.window.showWarningMessage(
      'Wax: game content is made with the Unreal Editor 4.27, and none was found. Point Wax at one you have, or install it into this folder (about 19 GB, with your Epic Games account).',
      CHOOSE, GET);
    if (choice === CHOOSE) await vscode.commands.executeCommand('wax.chooseUnreal');
    if (choice === GET) await vscode.commands.executeCommand('wax.installUnreal');
    return false;
  };
  app.content = { workspace: () => workspace(), editorFolder: () => { const root = workspace(); return root ? editorFolder(root) : null; } };

  const run = (root, line, show) => {
    if (!terminal || terminal.exitStatus !== undefined) {
      const engine = editorFolder(root);
      terminal = vscode.window.createTerminal({ name: 'Wax content', cwd: root, env: engine ? { WAX_UNREAL_ENGINE: engine } : {} });
    }
    if (show) terminal.show(true);
    terminal.sendText(line, true);
  };

  const build = (root, id, show) => run(root, `node wax/cli/content.mjs build ${id}`, show);

  app.command('wax.buildContent', async (arg) => {
    const root = needWorkspace();
    if (!root) return;
    const mod = await app.pickMod(arg, 'Build the game content of which mod?');
    if (!mod) return;
    if (!(await needEditor(root))) return;
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

  // Picks the folder of an Unreal Editor 4.27 that is already on this PC, and keeps it in the settings.
  app.command('wax.chooseUnreal', async () => {
    const picked = await vscode.window.showOpenDialog({
      title: 'The folder of Unreal Engine 4.27 (the one that holds Engine)', openLabel: 'Use This Editor',
      canSelectFolders: true, canSelectFiles: false, canSelectMany: false,
    });
    if (!picked || !picked.length) return;
    const folder = picked[0].fsPath;
    if (!fs.existsSync(path.join(folder, ...EDITOR))) {
      vscode.window.showErrorMessage(`Wax: ${folder} is not an Unreal Editor 4.27. It has no Engine\\Binaries\\Win64\\UE4Editor-Cmd.exe.`);
      return;
    }
    await vscode.workspace.getConfiguration('wax').update('unrealPath', folder, vscode.ConfigurationTarget.Global);
    if (terminal) terminal.dispose();
    terminal = null;
    vscode.window.showInformationMessage(`Wax: game content is now cooked with the editor in ${folder}.`);
  });

  // Downloads the editor into the open folder: only the parts that cooking needs.
  app.command('wax.installUnreal', async () => {
    const root = needWorkspace();
    if (!root) return;
    if (!fs.existsSync(path.join(root, ...INSTALL))) {
      vscode.window.showWarningMessage('Wax: this folder has no scripts/Install-UnrealEditor.ps1.');
      return;
    }
    const go = 'Install';
    const choice = await vscode.window.showWarningMessage('Install the Unreal Editor 4.27 into this folder?', {
      modal: true,
      detail: 'It is about 19 GB and comes from Epic Games, so it needs your Epic Games account: the terminal asks you to sign in the first time. Only the editor and what cooking needs are fetched. If you already have Unreal Engine 4.27, choose its folder with "Wax: Choose the Unreal Editor Folder" and nothing is downloaded.',
    }, go);
    if (choice !== go) return;
    run(root, `pwsh -NoProfile -File ${INSTALL.join('/')}`, true);
  });

  app.command('wax.openUnreal', async () => {
    const root = needWorkspace();
    if (!root) return;
    if (!(await needEditor(root))) return;
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
      if (event.affectsConfiguration('wax.unrealPath') && terminal) {
        terminal.dispose();
        terminal = null;
      }
    }),
    vscode.workspace.onDidChangeWorkspaceFolders(rewatch),
    { dispose: () => { if (watcher) watcher.dispose(); for (const timer of timers.values()) clearTimeout(timer); } },
  );
  rewatch();
}

module.exports = { register };
