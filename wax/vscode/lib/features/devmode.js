'use strict';
// Developer mode: a file named dev.txt in the game's Wax folder. While it is there the game runs Lua sent from outside it
const fs = require('node:fs');
const path = require('node:path');

const ON = 'Switch Developer Mode On';
const NOTE = 'Developer mode is on for this copy of Wax. Programs on this PC can run Lua in the game through its run folder, and Wax does not update itself.\r\n'
  + 'Delete this file to switch developer mode off.\r\n';
const ALLOWS = 'While it is on, any program on this PC can run Lua in the game, and Lua in the game can do what a program can. '
  + 'Run File, Reload Mod, the log and the Mods view reach the game that way. Wax also stops updating itself while it is on. '
  + 'Switch it off again when you are done writing mods.';

function register(app) {
  const { vscode } = app;

  const file = () => (app.runtime ? path.join(app.runtime, 'dev.txt') : null);
  const isOn = () => {
    const target = file();
    return Boolean(target && fs.existsSync(target));
  };
  app.devMode = { file, isOn };

  // Shown when the game refused Lua: says why, and offers the switch.
  app.offerDevMode = async () => {
    const choice = await vscode.window.showWarningMessage(
      'Wax: developer mode is off, so the game did not run this. The game runs Lua sent from the editor only while developer mode is on.', ON);
    if (choice === ON) await vscode.commands.executeCommand('wax.devModeOn');
  };

  app.command('wax.devModeOn', async () => {
    if (!app.needRuntime()) return;
    if (isOn()) {
      vscode.window.showInformationMessage(`Wax: developer mode is already on for the Wax at ${app.runtime}.`);
      app.game.schedule(0);
      return;
    }
    const choice = await vscode.window.showWarningMessage(`Switch developer mode on for the Wax at ${app.runtime}?`, { modal: true, detail: ALLOWS }, ON);
    if (choice !== ON) return;
    try {
      fs.writeFileSync(file(), NOTE, { flag: 'wx' });
    } catch (error) {
      throw new Error(`dev.txt could not be written in ${app.runtime} (${error.code ?? error.message}).`);
    }
    app.game.schedule(0);
    vscode.window.showInformationMessage('Wax: developer mode is on. A game that is running takes it up at once.');
  });

  app.command('wax.devModeOff', async () => {
    if (!app.needRuntime()) return;
    if (!isOn()) {
      vscode.window.showInformationMessage(`Wax: developer mode is already off for the Wax at ${app.runtime}.`);
      return;
    }
    // in a source checkout the same file keeps Wax from replacing the files being worked on
    if (app.found.source === 'workspace') {
      vscode.window.showWarningMessage(
        `Wax: ${app.runtime} is the development copy of Wax in the open folder. Its dev.txt also keeps Wax from updating its own files there, so it stays.`);
      return;
    }
    try {
      fs.rmSync(file());
    } catch (error) {
      throw new Error(`dev.txt could not be removed from ${app.runtime} (${error.code ?? error.message}).`);
    }
    app.game.schedule(0);
    vscode.window.showInformationMessage(
      'Wax: developer mode is off. The game no longer runs Lua sent from outside it. Run File, Reload Mod, the log and the Mods view stop until it is switched on again.');
  });
}

module.exports = { register, ON, ALLOWS };
