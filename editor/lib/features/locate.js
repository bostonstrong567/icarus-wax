'use strict';
// Says so when the game or Wax is missing, and lets the user choose the game folder
const paths = require('../paths');
const { DOWNLOAD } = require('../docs');

const CHOOSE = 'Choose the ICARUS folder';
const GET = 'Get Wax';
const ASKED = 'wax.askedAbout';

function register(app) {
  const { vscode, context } = app;
  let choosing = false;
  let warned = false;

  const ask = async () => {
    const what = paths.missing(app.found);
    context.globalState.update(ASKED, what.situation);
    const choice = await vscode.window.showWarningMessage(what.text, ...(what.gameFound ? [GET, CHOOSE] : [CHOOSE, GET]));
    if (choice === CHOOSE) await vscode.commands.executeCommand('wax.chooseGameFolder');
    else if (choice === GET) await vscode.commands.executeCommand('wax.getWax');
  };

  // Shows the one message about a missing game or a missing Wax, and does what the button pressed says.
  app.askForGame = () => ask().catch((error) => app.output.appendLine(String(error && error.message ? error.message : error)));

  // By itself the message shows once for each thing that is missing, and not again after VS Code restarts.
  app.events.on('located', ({ quiet = false } = {}) => {
    const found = app.found;
    // found: if Wax goes missing later, that is news again
    if (found.dir && context.globalState.get(ASKED)) context.globalState.update(ASKED, undefined);
    if (quiet || choosing) return;
    if (found.dir) {
      // a wrong setting is named once, even when it is typed letter by letter
      if (!found.problem || warned) return;
      warned = true;
      vscode.window.showWarningMessage(`${found.problem} The Wax folder at ${found.dir} is used.`, 'Open Settings').then((choice) => {
        if (choice) vscode.commands.executeCommand('workbench.action.openSettings', 'wax.');
      });
      return;
    }
    if (context.globalState.get(ASKED) !== paths.missing(found).situation) app.askForGame();
  });

  app.command('wax.chooseGameFolder', async () => {
    const picked = await vscode.window.showOpenDialog({
      title: 'Choose the ICARUS folder', openLabel: 'Use This Folder',
      canSelectFiles: false, canSelectFolders: true, canSelectMany: false,
      defaultUri: app.found.game ? vscode.Uri.file(app.found.game) : undefined,
    });
    if (!picked || !picked.length) return;
    const chosen = picked[0].fsPath;
    const there = paths.describeFolder(chosen);
    if (!there.runtime && !there.game) {
      const again = await vscode.window.showWarningMessage(
        `Wax: "${chosen}" is not the ICARUS folder. Look for the folder named Icarus under steamapps\\common in your Steam library.`, CHOOSE);
      if (again === CHOOSE) await vscode.commands.executeCommand('wax.chooseGameFolder');
      return;
    }
    const settings = vscode.workspace.getConfiguration('wax');
    choosing = true;
    try {
      await settings.update('gamePath', there.game ?? there.runtime, vscode.ConfigurationTarget.Global);
      // that setting is tried first, so it would hide this choice
      if (settings.get('runtimePath', '')) await settings.update('runtimePath', undefined, vscode.ConfigurationTarget.Global);
    } finally {
      choosing = false;
    }
    app.locate({ quiet: true });
    if (app.runtime) vscode.window.showInformationMessage(`Wax: found Wax at ${app.runtime}.`);
    else await app.askForGame();
  });

  app.command('wax.getWax', async () => {
    await vscode.env.openExternal(vscode.Uri.parse(DOWNLOAD));
  });
}

module.exports = { register, CHOOSE, GET, ASKED };
