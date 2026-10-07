'use strict';
// The "Wax" output channel, the status bar item, and the game's errors in the Problems panel
const { clock, formatEntry } = require('../logformat');

function register(app) {
  const { vscode, game, output, tracker } = app;
  const problems = vscode.languages.createDiagnosticCollection('wax-game');
  const status = vscode.window.createStatusBarItem('wax.status', vscode.StatusBarAlignment.Left, 0);
  status.name = 'Wax';
  status.command = 'wax.showLog';

  const render = () => {
    vscode.commands.executeCommand('setContext', 'wax.connected', game.connected);
    status.backgroundColor = undefined;
    status.command = 'wax.showLog';
    if (game.state === 'unset') {
      status.hide();
      return;
    }
    if (game.state === 'devoff') {
      status.text = '$(lock) Wax: developer mode is off';
      status.tooltip = 'ICARUS is running. Wax in it runs Lua sent from the editor only in developer mode. Click to switch it on.';
      status.command = 'wax.devModeOn';
    } else if (game.state === 'connected') {
      const count = game.mods.length;
      const failed = game.mods.filter((mod) => mod.status === 'failed').length;
      status.text = `$(plug) Wax: ${count} mod${count === 1 ? '' : 's'}${failed ? `, ${failed} failed` : ''}`;
      status.tooltip = 'Connected to ICARUS. Click to show the log.';
      if (failed) status.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
    } else if (game.state === 'nocore') {
      status.text = '$(warning) Wax: not running in the game';
      status.tooltip = 'The game answers, but Wax did not start in it. UE4SS.log says why.';
    } else if (game.state === 'busy') {
      status.text = '$(sync~spin) Wax: game not answering';
      status.tooltip = 'ICARUS is running but not answering. It is loading, or Wax is not installed in it.';
    } else {
      status.text = '$(debug-disconnect) Wax: game not running';
      status.tooltip = `Wax folder: ${app.runtime}. Click to show the log.`;
    }
    status.show();
  };

  // Mods as the problem finder needs them: the folders on disk, plus any the game loads from elsewhere.
  const knownMods = () => {
    const known = [...app.mods()];
    for (const mod of game.mods) {
      if (mod.dir && !known.some((other) => other.id === mod.id)) known.push({ id: mod.id, dir: mod.dir, files: [] });
    }
    return known;
  };

  const lineRange = (file, line) => {
    const open = vscode.workspace.textDocuments.find((document) => document.uri.scheme === 'file'
      && document.uri.fsPath.toLowerCase() === vscode.Uri.file(file).fsPath.toLowerCase());
    if (!open || line >= open.lineCount) return new vscode.Range(line, 0, line, 200);
    const text = open.lineAt(line);
    return new vscode.Range(line, text.firstNonWhitespaceCharacterIndex, line, text.text.length);
  };

  const publish = () => {
    const dirs = new Map(knownMods().map((mod) => [mod.id, mod.dir]));
    const byFile = new Map();
    for (const problem of tracker.all(dirs)) {
      const list = byFile.get(problem.path) ?? [];
      const diagnostic = new vscode.Diagnostic(lineRange(problem.path, Math.max(problem.line - 1, 0)), problem.message,
        vscode.DiagnosticSeverity.Error);
      diagnostic.source = problem.kind === 'load' ? 'Wax (did not load)' : 'Wax (in game)';
      list.push(diagnostic);
      byFile.set(problem.path, list);
    }
    problems.clear();
    for (const [file, list] of byFile) problems.set(vscode.Uri.file(file), list);
  };

  game.on('state', (state, previous) => {
    if (state === 'connected') output.appendLine(`${clock()} [info] [editor] connected to the game`);
    else if (state === 'devoff') output.appendLine(`${clock()} [info] [editor] the game is running with developer mode off, so it runs no Lua sent from the editor. "Wax: Switch Developer Mode On" changes that.`);
    else if (previous === 'connected') output.appendLine(`${clock()} [info] [editor] ${state === 'absent' ? 'the game is gone' : 'the game stopped answering'}`);
    render();
  });
  game.on('log', (entries) => {
    for (const entry of entries) output.appendLine(formatEntry(entry));
    // only errors and the loader's own lines can change the problems; the rest need no look at the disk
    const telling = entries.filter((entry) => entry.level === 'error' || entry.channel === 'wax.mods');
    if (telling.length && tracker.apply(telling, knownMods())) publish();
  });
  game.on('mods', (mods) => {
    render();
    if (game.connected && tracker.sync(mods, knownMods())) publish();
  });
  game.on('problem', (error) => output.appendLine(`${clock()} [warn] [editor] ${error.message}`));

  app.command('wax.showLog', () => output.show(true));

  app.context.subscriptions.push(problems, status);
  app.events.on('located', render);
  render();
}

module.exports = { register };
