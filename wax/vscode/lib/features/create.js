'use strict';
// New Mod and New Script
const fs = require('node:fs');
const names = require('../names');
const templates = require('../templates');
const { listLuaFiles } = require('../mods');
const { isInside } = require('../paths');

function register(app) {
  const { vscode } = app;

  const open = async (file) => vscode.window.showTextDocument(await vscode.workspace.openTextDocument(vscode.Uri.file(file)));

  // After the files exist: tell the game, and say what happens next.
  const announce = async (made) => {
    const actions = [];
    let text = `${made.id} was created in ${made.dir}.`;
    if (app.game.connected) {
      await app.game.refresh().catch(() => {});
      const seen = app.game.mods.find((mod) => mod.id === made.id);
      if (seen && seen.status === 'loaded') {
        text = `${made.id} was created and is running in the game.`;
      } else if (seen) {
        text = `${made.id} was created. A mod that shows up while the game is running starts switched off.`;
        actions.push('Enable in Game');
      }
    } else {
      text += ' It loads the next time the game starts.';
    }
    const inWorkspace = app.folders.some((folder) => isInside(folder, made.dir));
    if (!inWorkspace) actions.push('Add Folder to Workspace');
    const choice = await vscode.window.showInformationMessage(`Wax: ${text}`, ...actions);
    if (choice === 'Enable in Game') {
      await app.game.setEnabled(made.id, true);
    } else if (choice === 'Add Folder to Workspace') {
      const count = (vscode.workspace.workspaceFolders ?? []).length;
      vscode.workspace.updateWorkspaceFolders(count, 0, { uri: vscode.Uri.file(made.dir), name: `mod: ${made.id}` });
    }
  };

  app.command('wax.newMod', async () => {
    const modsDir = app.modsDir;
    if (!modsDir) {
      app.needRuntime();
      return;
    }
    const existing = () => {
      try { return fs.readdirSync(modsDir); } catch { return []; }
    };
    // nothing is written until all three questions are answered
    const name = await vscode.window.showInputBox({
      title: 'New Mod (1 of 3): name',
      prompt: 'A name for the mod. Its folder gets the name without spaces.',
      placeHolder: 'My Mod',
      validateInput: (value) => names.modNameProblem(value, existing()),
    });
    if (name === undefined) return;
    const description = await vscode.window.showInputBox({
      title: 'New Mod (2 of 3): description',
      prompt: 'One line that says what the mod does. You can leave it empty.',
      placeHolder: 'Shows the map I am on',
    });
    if (description === undefined) return;
    const start = await vscode.window.showQuickPick(
      templates.STARTS.map((entry) => ({ label: entry.label, detail: entry.detail, id: entry.id })),
      { title: 'New Mod (3 of 3): starting point', placeHolder: 'Pick what init.lua starts as' });
    if (!start) return;
    const made = templates.createMod(modsDir, name, { description, start: start.id });
    app.scanned = null;
    app.setUpEditor({ quiet: true });
    app.events.emit('changed');
    await open(made.init);
    await announce(made);
  });

  app.command('wax.newScript', async (arg) => {
    const mod = await app.pickMod(arg, 'Add a script to which mod?');
    if (!mod || !mod.dir) return;
    const name = await vscode.window.showInputBox({
      title: `New Script in ${mod.id}`,
      prompt: 'Name the script. A dot puts it in a folder: Utils, or extras.Utils for extras\\Utils.lua.',
      placeHolder: 'Utils',
      validateInput: (value) => names.moduleNameProblem(value, listLuaFiles(mod.dir)),
    });
    if (name === undefined) return;
    const made = templates.createModule(mod.dir, name, listLuaFiles(mod.dir));
    app.scanned = null;
    app.events.emit('changed');
    await open(made.file);
    vscode.window.setStatusBarMessage(`Wax: use it with ${names.requireText(made.name)}`, 6000);
  });
}

module.exports = { register };
