'use strict';
// Run File / Run Selection in the game, Stop Scripts, and Reload Mod
const path = require('node:path');
const { clock, firstLine, trimTrace, locateInChunk } = require('../logformat');
const { isInside } = require('../paths');

function register(app) {
  const { vscode } = app;
  const problems = vscode.languages.createDiagnosticCollection('wax-run');

  const documentFor = (arg) => {
    if (arg && typeof arg.fsPath === 'string') {
      const open = vscode.workspace.textDocuments.find((document) => document.uri.toString() === arg.toString());
      if (open) return open;
    }
    return vscode.window.activeTextEditor ? vscode.window.activeTextEditor.document : null;
  };

  // Sends `source` to the game and shows what came back; `what` names the part of the document for the log.
  const run = async (document, source, { fresh, expression, what }) => {
    if (!app.needRuntime()) return;
    const found = document.uri.scheme === 'file' ? app.modOf(document.uri.fsPath) : null;
    const chunkname = found ? `${found.mod.id}/${found.relative}` : path.basename(document.fileName);
    const working = vscode.window.setStatusBarMessage(`$(sync~spin) Wax: running ${what}`);
    let result;
    try {
      result = await app.game.run({ source, chunkname, modId: found ? found.mod.id : null, fresh, expression });
    } finally {
      working.dispose();
    }
    const out = app.output;
    out.appendLine(`${clock()} [run] ${what} of ${chunkname}, as ${result.as}`);
    if (!result.ok) {
      for (const line of trimTrace(result.error).split('\n')) out.appendLine('    ' + line.replace(/^\t/, ''));
      const at = locateInChunk(result.error, chunkname);
      if (at) {
        const line = Math.min(Math.max(at.line - 1, 0), document.lineCount - 1);
        const diagnostic = new vscode.Diagnostic(document.lineAt(line).range, at.message, vscode.DiagnosticSeverity.Error);
        diagnostic.source = 'Wax (run)';
        problems.set(document.uri, [diagnostic]);
      }
      out.show(true);
      vscode.window.showErrorMessage(`Wax: ${firstLine(result.error)}`);
      return;
    }
    problems.delete(document.uri);
    if (result.waiting) out.appendLine('    still running: it paused. What it prints, and any error, appears in this log.');
    for (const value of result.values) out.appendLine(`    = ${value}`);
    if (!result.waiting && !result.values.length) out.appendLine('    done, no value returned');
    if (result.kept > 0) {
      out.appendLine(`    ${result.kept} thing${result.kept === 1 ? '' : 's'} it set up stay until this file is run again ("Wax: Stop Scripts Run from the Editor" removes them)`);
    }
    out.show(true);
    vscode.window.setStatusBarMessage(`Wax: ran ${what} of ${path.basename(document.fileName)}`, 4000);
  };

  app.command('wax.runFile', async (arg) => {
    const document = documentFor(arg);
    if (!document || document.languageId !== 'lua') {
      vscode.window.showInformationMessage('Wax: open a Lua file to run it in the game.');
      return;
    }
    await run(document, document.getText(), { fresh: true, expression: false, what: 'the file' });
  });

  app.command('wax.runSelection', async () => {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.languageId !== 'lua') {
      vscode.window.showInformationMessage('Wax: select some Lua to run it in the game.');
      return;
    }
    const { document, selection } = editor;
    // nothing selected: the line the cursor is on
    const range = selection.isEmpty ? document.lineAt(selection.active.line).range : selection;
    const text = document.getText(range);
    if (!text.trim()) return;
    // blank lines in front keep the line numbers in errors the same as in the file
    const source = '\n'.repeat(range.start.line) + text;
    const lines = range.start.line === range.end.line ? `line ${range.start.line + 1}` : `lines ${range.start.line + 1} to ${range.end.line + 1}`;
    await run(document, source, { fresh: false, expression: true, what: lines });
  });

  app.command('wax.stopScripts', async () => {
    if (!app.needRuntime()) return;
    const removed = await app.game.stopScripts();
    problems.clear();
    vscode.window.setStatusBarMessage(
      removed ? `Wax: removed ${removed} thing${removed === 1 ? '' : 's'} left by scripts run from the editor` : 'Wax: nothing was left running', 5000);
  });

  app.command('wax.reloadMod', async (arg) => {
    if (!app.needRuntime()) return;
    const mod = await app.pickMod(arg, 'Reload which mod?');
    if (!mod) return;
    // the game reads the files from disk, so what is unsaved has to be saved first
    for (const document of vscode.workspace.textDocuments) {
      if (document.isDirty && document.uri.scheme === 'file' && mod.dir && isInside(mod.dir, document.uri.fsPath)) await document.save();
    }
    await app.game.reload(mod.id);
    const now = app.game.mods.find((other) => other.id === mod.id);
    if (!now) {
      vscode.window.showWarningMessage(`Wax: the game has not found ${mod.id}. Check that its folder is in the mods folder the game uses.`);
    } else if (now.status === 'loaded') {
      const took = typeof now.loadMs === 'number' ? ` in ${now.loadMs.toFixed(1)} ms` : '';
      vscode.window.setStatusBarMessage(`$(check) Wax: ${mod.id} reloaded${took}`, 4000);
    } else if (now.status === 'disabled') {
      const choice = await vscode.window.showInformationMessage(`Wax: ${mod.id} is switched off in the game.`, 'Enable');
      if (choice) await app.game.setEnabled(mod.id, true);
    } else {
      const choice = await vscode.window.showErrorMessage(`Wax: ${mod.id} did not load: ${now.error ?? now.status}`, 'Show Log');
      if (choice) app.output.show(true);
    }
  });

  // Decides whether the reload button shows: only for files of a mod.
  const mark = (editor) => {
    const document = editor && editor.document;
    const inMod = Boolean(document && document.uri.scheme === 'file' && document.languageId === 'lua' && app.modOf(document.uri.fsPath));
    vscode.commands.executeCommand('setContext', 'wax.editorInMod', inMod);
  };
  const markActive = () => mark(vscode.window.activeTextEditor);

  app.context.subscriptions.push(
    problems,
    vscode.window.onDidChangeActiveTextEditor(mark),
    vscode.workspace.onDidCloseTextDocument((document) => problems.delete(document.uri)),
  );
  app.events.on('located', markActive);
  app.events.on('changed', markActive);
}

module.exports = { register };
