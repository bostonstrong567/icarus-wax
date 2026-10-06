'use strict';
// Editor support: writes the .luarc.json files that point the Lua language server at Wax's definitions
const support = require('../support');
const { isInside } = require('../paths');

function register(app) {
  const { vscode } = app;

  // quiet: say nothing (for the times it runs by itself).
  app.setUpEditor = ({ quiet = false } = {}) => {
    let result;
    try {
      result = support.setUp({ folders: app.folders, modsDir: app.modsDir, extensionDir: app.extensionDir });
    } catch (error) {
      result = { problem: error.message };
    }
    if (quiet) return result;
    if (result.problem) {
      vscode.window.showWarningMessage(`Wax: ${result.problem}`);
    } else if (!result.mods.length) {
      vscode.window.showInformationMessage('Wax: there are no mods to set up yet. Make one with "Wax: New Mod".');
    } else {
      const count = result.mods.length;
      const from = result.where.live ? 'this workspace' : 'the extension';
      vscode.window.showInformationMessage(
        `Wax: editor support is set up for ${count} mod${count === 1 ? '' : 's'} (definitions from ${from}).`);
    }
    return result;
  };

  // By itself the extension only writes into mods the user has open.
  const auto = () => {
    const open = app.modsDir && app.folders.some((folder) => isInside(folder, app.modsDir) || isInside(app.modsDir, folder));
    if (open) app.setUpEditor({ quiet: true });
  };

  app.command('wax.setUpEditor', () => app.setUpEditor());
  app.events.on('located', auto);
  app.events.on('changed', auto);
}

module.exports = { register };
