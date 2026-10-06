'use strict';
// The Mods view in the activity bar
const fs = require('node:fs');
const path = require('node:path');
const { isInside } = require('../paths');

function register(app) {
  const { vscode, game } = app;
  const changed = new vscode.EventEmitter();

  const icon = (mod) => {
    if (!mod.inGame) return new vscode.ThemeIcon('package');
    if (mod.status === 'loaded') return new vscode.ThemeIcon('pass', new vscode.ThemeColor('testing.iconPassed'));
    if (mod.status === 'failed') return new vscode.ThemeIcon('error', new vscode.ThemeColor('testing.iconFailed'));
    if (mod.status === 'disabled') return new vscode.ThemeIcon('circle-slash');
    return new vscode.ThemeIcon('circle-outline');
  };

  const statusWords = (mod) => {
    if (mod.status === 'disabled') return mod.fresh ? 'new, switched off until enabled' : 'switched off';
    if (mod.status === 'failed') return 'failed';
    return mod.status;
  };

  const provider = {
    onDidChangeTreeData: changed.event,
    getChildren: (element) => (element ? [] : app.listMods()),
    getTreeItem: (mod) => {
      const item = new vscode.TreeItem(mod.name, vscode.TreeItemCollapsibleState.None);
      item.id = mod.id;
      item.description = [mod.version, statusWords(mod)].filter(Boolean).join('  ');
      item.iconPath = icon(mod);
      item.contextValue = !mod.inGame ? 'mod.disk' : mod.enabled ? 'mod.on' : 'mod.off';
      item.tooltip = [mod.name === mod.id ? mod.id : `${mod.name} (${mod.id})`, mod.description, mod.dir, mod.error].filter(Boolean).join('\n');
      return item;
    },
  };
  const view = vscode.window.createTreeView('wax.mods', { treeDataProvider: provider });

  const refresh = () => {
    view.message = game.connected || game.state === 'unset' ? undefined : 'The game is not running. These are the mods on disk.';
    changed.fire();
  };

  app.command('wax.refreshMods', async () => {
    app.scanned = null;
    // the game looks at its folders again; a mod it has not seen before is listed switched off
    if (game.connected) await game.refresh();
    refresh();
  });

  const setEnabled = (enabled) => async (arg) => {
    if (!app.needRuntime()) return;
    const mod = await app.pickMod(arg, enabled ? 'Enable which mod?' : 'Disable which mod?');
    if (!mod) return;
    await game.setEnabled(mod.id, enabled);
    const now = game.mods.find((other) => other.id === mod.id);
    if (enabled && now && now.status === 'failed') {
      vscode.window.showErrorMessage(`Wax: ${mod.id} did not load: ${now.error ?? 'see the log'}`);
    }
  };
  app.command('wax.enableMod', setEnabled(true));
  app.command('wax.disableMod', setEnabled(false));

  app.command('wax.openMod', async (arg) => {
    const mod = await app.pickMod(arg, 'Open which mod?');
    if (!mod || !mod.dir) return;
    const file = [mod.main || 'init.lua', 'init.lua', 'mod.lua'].map((name) => path.join(mod.dir, name)).find((name) => fs.existsSync(name));
    if (!file) throw new Error(`${mod.id} has no init.lua`);
    await vscode.window.showTextDocument(await vscode.workspace.openTextDocument(vscode.Uri.file(file)));
  });

  // Shows the mod's folder in the Explorer, adding it to the workspace first when it is not part of it.
  app.command('wax.openModFolder', async (arg) => {
    const mod = await app.pickMod(arg, 'Open the folder of which mod?');
    if (!mod || !mod.dir) return;
    const uri = vscode.Uri.file(mod.dir);
    const folders = vscode.workspace.workspaceFolders ?? [];
    const inside = folders.some((folder) => isInside(folder.uri.fsPath, mod.dir));
    if (!inside) vscode.workspace.updateWorkspaceFolders(folders.length, 0, { uri, name: `mod: ${mod.id}` });
    await vscode.commands.executeCommand('revealInExplorer', uri);
  });

  game.on('state', refresh);
  game.on('mods', refresh);
  app.events.on('located', refresh);
  app.events.on('changed', refresh);
  app.context.subscriptions.push(view, changed);
}

module.exports = { register };
