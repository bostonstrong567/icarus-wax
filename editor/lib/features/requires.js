'use strict';
// require("...") in mod files: completion, a check of what the loader would refuse, and the fix for the manifest
const fs = require('node:fs');
const path = require('node:path');
const requires = require('../requires');
const { PROBLEMS } = require('../docs');

const LUA = { language: 'lua', scheme: 'file' };
const SOURCE = 'Wax';

function register(app) {
  const { vscode } = app;
  const collection = vscode.languages.createDiagnosticCollection('wax-requires');
  const timers = new Map();

  // The mod a document belongs to, with its files and dependencies as they are on disk now.
  const modFor = (document) => {
    if (document.languageId !== 'lua' || document.uri.scheme !== 'file') return null;
    const found = app.modOf(document.uri.fsPath);
    return found ? found.mod : null;
  };

  const check = (document) => {
    const mod = modFor(document);
    if (!mod) {
      collection.delete(document.uri);
      return;
    }
    const problems = requires.checkRequires({ text: document.getText(), mod, mods: app.mods() });
    collection.set(document.uri, problems.map((problem) => {
      const range = new vscode.Range(document.positionAt(problem.start), document.positionAt(problem.end));
      const diagnostic = new vscode.Diagnostic(range, problem.message, vscode.DiagnosticSeverity.Error);
      diagnostic.source = SOURCE;
      // the code shows as a link to the page that explains the problem
      diagnostic.code = { value: problem.code, target: vscode.Uri.parse(app.docs(PROBLEMS[problem.code]).url) };
      return diagnostic;
    }));
  };

  const checkSoon = (document) => {
    if (document.languageId !== 'lua') return;
    const key = document.uri.toString();
    clearTimeout(timers.get(key));
    timers.set(key, setTimeout(() => {
      timers.delete(key);
      check(document);
    }, 300));
  };

  const checkAll = () => vscode.workspace.textDocuments.forEach(check);

  const completion = {
    provideCompletionItems(document, position) {
      const line = document.lineAt(position.line).text;
      const context = requires.requireContext(line.slice(0, position.character));
      const mod = context && modFor(document);
      if (!mod) return undefined;
      let end = position.character;
      while (end < line.length && !/["'\s)]/.test(line[end])) end++;
      const range = {
        inserting: new vscode.Range(position.line, context.start, position.line, position.character),
        replacing: new vscode.Range(position.line, context.start, position.line, end),
      };
      return requires.requireCandidates({ mod, mods: app.mods(), partial: context.partial }).map((candidate, index) => {
        const kind = candidate.kind === 'mod' ? vscode.CompletionItemKind.Module : vscode.CompletionItemKind.File;
        const item = new vscode.CompletionItem(candidate.label, kind);
        item.detail = candidate.detail;
        const help = app.docs(candidate.kind === 'mod' ? 'mods#using-another-mod' : 'mods#more-than-one-file');
        item.documentation = new vscode.MarkdownString(help.markdown);
        item.range = range;
        item.filterText = candidate.label;
        item.sortText = String(index).padStart(4, '0');
        return item;
      });
    },
  };

  const fixes = {
    provideCodeActions(document, _range, context) {
      const mod = modFor(document);
      if (!mod) return [];
      const actions = [];
      for (const diagnostic of context.diagnostics) {
        if (diagnostic.source !== SOURCE || !diagnostic.code || diagnostic.code.value !== 'undeclared') continue;
        const id = document.getText(diagnostic.range).replace(/^@/, '');
        const action = new vscode.CodeAction(`Add "${id}" to dependencies in mod.lua`, vscode.CodeActionKind.QuickFix);
        action.diagnostics = [diagnostic];
        action.isPreferred = true;
        action.command = { command: 'wax.addDependency', title: action.title, arguments: [mod.dir, id] };
        actions.push(action);
      }
      return actions;
    },
  };

  app.command('wax.addDependency', async (modDir, id) => {
    if (typeof modDir !== 'string' || typeof id !== 'string') return;
    const file = path.join(modDir, 'mod.lua');
    const uri = vscode.Uri.file(file);
    const exists = fs.existsSync(file);
    const document = exists ? await vscode.workspace.openTextDocument(uri) : null;
    const before = document ? document.getText() : null;
    const after = requires.addDependency(before, id);
    if (after === null) {
      vscode.window.showWarningMessage(`Wax: mod.lua could not be changed for you. Add "${id}" to its dependencies by hand.`);
      if (document) await vscode.window.showTextDocument(document);
      return;
    }
    if (after === before) return;
    const edit = new vscode.WorkspaceEdit();
    if (document) {
      edit.replace(uri, new vscode.Range(document.positionAt(0), document.positionAt(before.length)), after);
    } else {
      edit.createFile(uri, { ignoreIfExists: true });
      edit.insert(uri, new vscode.Position(0, 0), after);
    }
    if (!(await vscode.workspace.applyEdit(edit))) throw new Error('could not change mod.lua');
    await (await vscode.workspace.openTextDocument(uri)).save();
    app.scanned = null;
    app.events.emit('changed');
  });

  app.context.subscriptions.push(
    collection,
    vscode.languages.registerCompletionItemProvider(LUA, completion, '"', "'", '@', '.', '/'),
    vscode.languages.registerCodeActionsProvider(LUA, fixes, { providedCodeActionKinds: [vscode.CodeActionKind.QuickFix] }),
    vscode.workspace.onDidOpenTextDocument(check),
    vscode.workspace.onDidChangeTextDocument((event) => checkSoon(event.document)),
    vscode.workspace.onDidSaveTextDocument((document) => {
      if (path.basename(document.uri.fsPath) !== 'mod.lua') return;
      app.scanned = null;
      app.events.emit('changed');
    }),
    vscode.workspace.onDidCloseTextDocument((document) => {
      clearTimeout(timers.get(document.uri.toString()));
      timers.delete(document.uri.toString());
      collection.delete(document.uri);
    }),
    { dispose: () => timers.forEach((timer) => clearTimeout(timer)) },
  );
  app.events.on('located', checkAll);
  app.events.on('changed', checkAll);
}

module.exports = { register };
