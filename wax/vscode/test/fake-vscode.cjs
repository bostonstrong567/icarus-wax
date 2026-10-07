'use strict';
// A small stand-in for the "vscode" module: just what the extension uses, recording what it does.
// Names here are the real API's names, so a misspelt call in the extension fails the smoke test.
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');

class Disposable {
  constructor(undo) { this.undo = undo; }
  dispose() { if (this.undo) this.undo(); this.undo = null; }
}

class EventEmitter {
  constructor() {
    this.listeners = new Set();
    this.event = (listener) => {
      this.listeners.add(listener);
      return new Disposable(() => this.listeners.delete(listener));
    };
  }
  fire(value) { for (const listener of [...this.listeners]) listener(value); }
  dispose() { this.listeners.clear(); }
}

class Uri {
  constructor(scheme, fsPath, text) { this.scheme = scheme; this.fsPath = fsPath; this.text = text; }
  static file(file) {
    const full = path.resolve(file);
    return new Uri('file', full, 'file:///' + full.replace(/\\/g, '/'));
  }
  static parse(text) { return new Uri(text.slice(0, text.indexOf(':')), text, text); }
  toString() { return this.text; }
}

class Position {
  constructor(line, character) { this.line = line; this.character = character; }
}

class Range {
  constructor(a, b, c, d) {
    if (a instanceof Position) { this.start = a; this.end = b; } else { this.start = new Position(a, b); this.end = new Position(c, d); }
  }
  get isEmpty() { return this.start.line === this.end.line && this.start.character === this.end.character; }
}

class Selection extends Range {
  get active() { return this.end; }
}

class Diagnostic {
  constructor(range, message, severity) { this.range = range; this.message = message; this.severity = severity; }
}

class CompletionItem {
  constructor(label, kind) { this.label = label; this.kind = kind; }
}

class CodeAction {
  constructor(title, kind) { this.title = title; this.kind = kind; }
}

class MarkdownString {
  constructor(value = '') { this.value = value; }
}

class Hover {
  constructor(contents, range) { this.contents = contents; this.range = range; }
}

class TreeItem {
  constructor(label, collapsibleState) { this.label = label; this.collapsibleState = collapsibleState; }
}

class ThemeIcon {
  constructor(id, color) { this.id = id; this.color = color; }
}

class ThemeColor {
  constructor(id) { this.id = id; }
}

class RelativePattern {
  constructor(base, pattern) { this.base = base; this.pattern = pattern; }
}

class WorkspaceEdit {
  constructor() { this.steps = []; }
  replace(uri, range, text) { this.steps.push({ kind: 'replace', uri, range, text }); }
  insert(uri, position, text) { this.steps.push({ kind: 'insert', uri, position, text }); }
  createFile(uri, options) { this.steps.push({ kind: 'create', uri, options }); }
}

function create({ folders = [], settings = {} } = {}) {
  const events = {
    configuration: new EventEmitter(), folders: new EventEmitter(), activeEditor: new EventEmitter(), windowState: new EventEmitter(),
    opened: new EventEmitter(), changed: new EventEmitter(), saved: new EventEmitter(), closed: new EventEmitter(),
  };
  const state = {
    commands: new Map(), contexts: {}, messages: [], statusItems: [], statusMessages: [], channels: new Map(), diagnostics: new Map(),
    completions: [], codeActions: [], hovers: [], views: new Map(), watchers: [], shown: [], external: [], executed: [], documents: [],
    // settingsSaved: what the extension wrote into the settings, as { key, value, target }
    settings: { ...settings }, settingsSaved: [], folders: [...folders],
    // decides what the user "does" when asked something: (kind, detail) => answer
    reply: () => undefined,
  };

  class TextDocument {
    constructor(uri, text, languageId) {
      this.uri = uri;
      this.text = text;
      this.languageId = languageId;
      this.isDirty = false;
    }
    get fileName() { return this.uri.fsPath; }
    get lineCount() { return this.text.split('\n').length; }
    offsetAt(position) {
      const lines = this.text.split('\n');
      let offset = 0;
      for (let i = 0; i < position.line; i++) offset += lines[i].length + 1;
      return offset + position.character;
    }
    positionAt(offset) {
      const before = this.text.slice(0, offset).split('\n');
      return new Position(before.length - 1, before[before.length - 1].length);
    }
    getText(range) {
      return range ? this.text.slice(this.offsetAt(range.start), this.offsetAt(range.end)) : this.text;
    }
    lineAt(where) {
      const line = typeof where === 'number' ? where : where.line;
      const text = this.text.split('\n')[line].replace(/\r$/, '');
      return { lineNumber: line, text, range: new Range(line, 0, line, text.length), firstNonWhitespaceCharacterIndex: text.search(/\S|$/) };
    }
    async save() {
      fs.mkdirSync(path.dirname(this.uri.fsPath), { recursive: true });
      fs.writeFileSync(this.uri.fsPath, this.text);
      this.isDirty = false;
      events.saved.fire(this);
      return true;
    }
  }

  const languageOf = (file) => (file.endsWith('.lua') ? 'lua' : file.endsWith('.json') ? 'json' : 'plaintext');
  const findDocument = (uri) => state.documents.find((document) => document.uri.toString().toLowerCase() === uri.toString().toLowerCase());

  // like the real one, a message may be given options ({ modal, detail }) before its buttons
  const message = (level) => async (text, ...items) => {
    const options = items.length && typeof items[0] === 'object' ? items.shift() : null;
    const shown = options ? { level, text, items, options } : { level, text, items };
    state.messages.push(shown);
    return state.reply('message', shown);
  };

  const vscode = {
    Disposable, EventEmitter, Uri, Position, Range, Selection, Diagnostic, CompletionItem, CodeAction, TreeItem, ThemeIcon, ThemeColor,
    RelativePattern, WorkspaceEdit, MarkdownString, Hover,
    ConfigurationTarget: { Global: 1, Workspace: 2, WorkspaceFolder: 3 },
    DiagnosticSeverity: { Error: 0, Warning: 1, Information: 2, Hint: 3 },
    CompletionItemKind: { Module: 8, File: 16 },
    CodeActionKind: { QuickFix: 'quickfix' },
    TreeItemCollapsibleState: { None: 0, Collapsed: 1, Expanded: 2 },
    StatusBarAlignment: { Left: 1, Right: 2 },
    env: {
      openExternal: async (uri) => { state.external.push(uri.toString()); return true; },
    },
    commands: {
      registerCommand(id, handler) {
        if (state.commands.has(id)) throw new Error(`command ${id} registered twice`);
        state.commands.set(id, handler);
        return new Disposable(() => state.commands.delete(id));
      },
      async executeCommand(id, ...args) {
        if (id === 'setContext') { state.contexts[args[0]] = args[1]; return undefined; }
        state.executed.push({ id, args });
        const handler = state.commands.get(id);
        return handler ? handler(...args) : undefined;
      },
    },
    window: {
      activeTextEditor: undefined,
      onDidChangeActiveTextEditor: events.activeEditor.event,
      onDidChangeWindowState: events.windowState.event,
      async showOpenDialog(options) {
        const picked = state.reply('open', options);
        return picked ? [Uri.file(picked)] : undefined;
      },
      createOutputChannel(name, languageId) {
        const lines = [];
        state.channels.set(name, { lines, languageId, revealed: 0 });
        return { name, appendLine: (line) => lines.push(line), show: () => { state.channels.get(name).revealed += 1; }, dispose() {} };
      },
      createStatusBarItem(id, alignment, priority) {
        const item = { id, alignment, priority, text: '', tooltip: '', command: undefined, name: '', backgroundColor: undefined, visible: false,
          show() { this.visible = true; }, hide() { this.visible = false; }, dispose() {} };
        state.statusItems.push(item);
        return item;
      },
      setStatusBarMessage(text) {
        state.statusMessages.push(text);
        return new Disposable();
      },
      showInformationMessage: message('info'),
      showWarningMessage: message('warning'),
      showErrorMessage: message('error'),
      async showInputBox(options) { return state.reply('input', options); },
      async showQuickPick(items, options) { return state.reply('pick', { items, options }); },
      async showTextDocument(document) {
        state.shown.push(document.uri.fsPath);
        vscode.window.activeTextEditor = { document, selection: new Selection(0, 0, 0, 0) };
        events.activeEditor.fire(vscode.window.activeTextEditor);
        return vscode.window.activeTextEditor;
      },
      createTreeView(id, options) {
        const view = { id, provider: options.treeDataProvider, message: undefined, refreshed: 0, dispose() {} };
        options.treeDataProvider.onDidChangeTreeData(() => { view.refreshed += 1; });
        state.views.set(id, view);
        return view;
      },
    },
    workspace: {
      get workspaceFolders() {
        return state.folders.length ? state.folders.map((folder, index) => ({ uri: Uri.file(folder), name: path.basename(folder), index })) : undefined;
      },
      get textDocuments() { return state.documents; },
      getConfiguration(section) {
        // like the real one, this is what the settings were when it was asked for
        const then = { ...state.settings };
        return {
          get: (key, fallback) => (then[`${section}.${key}`] ?? fallback),
          async update(key, value, target) {
            const name = `${section}.${key}`;
            if (value === undefined) delete state.settings[name]; else state.settings[name] = value;
            state.settingsSaved.push({ key: name, value, target });
            events.configuration.fire({ affectsConfiguration: (asked) => name === asked || name.startsWith(`${asked}.`) });
          },
        };
      },
      onDidChangeConfiguration: events.configuration.event,
      onDidChangeWorkspaceFolders: events.folders.event,
      onDidOpenTextDocument: events.opened.event,
      onDidChangeTextDocument: events.changed.event,
      onDidSaveTextDocument: events.saved.event,
      onDidCloseTextDocument: events.closed.event,
      createFileSystemWatcher(pattern) {
        const watcher = { pattern, created: new EventEmitter(), deleted: new EventEmitter(), changed: new EventEmitter(), disposed: false };
        watcher.onDidCreate = watcher.created.event;
        watcher.onDidDelete = watcher.deleted.event;
        watcher.onDidChange = watcher.changed.event;
        watcher.dispose = () => { watcher.disposed = true; };
        state.watchers.push(watcher);
        return watcher;
      },
      async openTextDocument(uri) {
        const known = findDocument(uri);
        if (known) return known;
        const document = new TextDocument(uri, fs.readFileSync(uri.fsPath, 'utf8'), languageOf(uri.fsPath));
        state.documents.push(document);
        events.opened.fire(document);
        return document;
      },
      async applyEdit(edit) {
        for (const step of edit.steps) {
          let document = findDocument(step.uri);
          if (step.kind === 'create') {
            if (!document) {
              document = new TextDocument(step.uri, '', languageOf(step.uri.fsPath));
              state.documents.push(document);
            }
            continue;
          }
          if (!document) return false;
          const from = step.kind === 'insert' ? document.offsetAt(step.position) : document.offsetAt(step.range.start);
          const to = step.kind === 'insert' ? from : document.offsetAt(step.range.end);
          document.text = document.text.slice(0, from) + step.text + document.text.slice(to);
          document.isDirty = true;
          events.changed.fire({ document });
        }
        return true;
      },
      updateWorkspaceFolders(start, remove, ...added) {
        state.folders.splice(start, remove ?? 0, ...added.map((folder) => folder.uri.fsPath));
        events.folders.fire({});
        return true;
      },
    },
    languages: {
      createDiagnosticCollection(name) {
        const entries = new Map();
        state.diagnostics.set(name, entries);
        return {
          name,
          set: (uri, list) => entries.set(uri.toString(), list),
          delete: (uri) => entries.delete(uri.toString()),
          clear: () => entries.clear(),
          dispose() {},
        };
      },
      registerCompletionItemProvider(selector, provider, ...triggers) {
        state.completions.push({ selector, provider, triggers });
        return new Disposable();
      },
      registerCodeActionsProvider(selector, provider, metadata) {
        state.codeActions.push({ selector, provider, metadata });
        return new Disposable();
      },
      registerHoverProvider(selector, provider) {
        state.hovers.push({ selector, provider });
        return new Disposable();
      },
    },
  };

  // What a test does to play the user.
  const user = {
    events,
    // Opens a file as the active editor, optionally with text that differs from what is on disk.
    async open(file, text) {
      const document = await vscode.workspace.openTextDocument(Uri.file(file));
      if (text !== undefined) user.type(document, text);
      await vscode.window.showTextDocument(document);
      return document;
    },
    type(document, text) {
      document.text = text;
      document.isDirty = true;
      events.changed.fire({ document });
    },
    select(startLine, startCharacter, endLine, endCharacter) {
      vscode.window.activeTextEditor.selection = new Selection(startLine, startCharacter, endLine, endCharacter);
    },
    run: (id, ...args) => vscode.commands.executeCommand(id, ...args),
  };

  return { vscode, state, user };
}

// What VS Code hands to activate(). stored: what the extension remembered in an earlier session.
function context(extensionPath, stored = {}) {
  return {
    extensionPath, subscriptions: [], stored,
    globalState: {
      get: (key, fallback) => (stored[key] ?? fallback),
      async update(key, value) {
        if (value === undefined) delete stored[key]; else stored[key] = value;
      },
    },
  };
}

// Loads extension.js with `fake` standing in for the vscode module. Returns the extension's exports.
function load(extensionFile, fake) {
  const root = path.dirname(extensionFile);
  for (const key of Object.keys(require.cache)) {
    if (key.startsWith(root) && !key.includes(`${path.sep}test${path.sep}`)) delete require.cache[key];
  }
  const original = Module._load;
  Module._load = function (request, ...rest) {
    return request === 'vscode' ? fake : original.call(this, request, ...rest);
  };
  try {
    return require(extensionFile);
  } finally {
    Module._load = original;
  }
}

module.exports = { create, context, load };
