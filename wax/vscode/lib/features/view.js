'use strict';
// The Mods view in the activity bar
const fs = require('node:fs');
const path = require('node:path');
const { isInside } = require('../paths');
const { describeMod } = require('../mods');

const SKIP = new Set(['wax.origin', 'wax.new', '.luarc.json']);
const UNREAL = ['unreal', 'Icarus', 'Content', 'Mods'];
const UNREAL_ASSET = /\.(uasset|umap)$/i;

// Every file below dir that is not Lua, as "sub/name.png", sorted.
function otherFiles(dir, prefix = '') {
  const out = [];
  let entries = [];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const entry of entries) {
    if (entry.name.startsWith('.') || SKIP.has(entry.name)) continue;
    const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isDirectory()) out.push(...otherFiles(path.join(dir, entry.name), relative));
    else if (!entry.name.endsWith('.lua')) out.push(relative);
  }
  return out.sort();
}

// Every folder below dir, as "sub/inner", sorted. Folders whose name starts with a dot are left out.
function folders(dir, prefix = '') {
  const out = [];
  let entries = [];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
    const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
    out.push(relative, ...folders(path.join(dir, entry.name), relative));
  }
  return out.sort();
}

const FOLDER_NAME = /^[A-Za-z0-9_-]+$/;
// The kinds of file a mod may hold besides Lua, as the catalogue takes them.
const ASSET_KINDS = new Set(['.png', '.jpg', '.jpeg', '.webp', '.json', '.txt', '.md', '.ogg', '.wav', '.csv', '.obj']);

function sizeWords(file) {
  try {
    const bytes = fs.statSync(file).size;
    return bytes >= 1048576 ? `${(bytes / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(bytes / 1024))} KB`;
  } catch {
    return '';
  }
}

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
    if (mod.status === 'disabled') return mod.fresh ? 'new, switched off until you enable it' : 'switched off';
    if (mod.status === 'failed') return 'failed';
    return mod.status;
  };

  // The folder of the Unreal project that holds a mod's own assets, when an open folder has that project.
  const unrealFolder = (id) => {
    for (const folder of vscode.workspace.workspaceFolders ?? []) {
      const dir = path.join(folder.uri.fsPath, ...UNREAL, id);
      if (fs.existsSync(dir)) return dir;
    }
    return null;
  };

  // One level of a mod's Lua files: the folders first, then the files.
  const scriptLevel = (mod, files, prefix, dirs = []) => {
    const folders = new Set();
    const here = [];
    for (const dir of dirs) {
      if (prefix && !dir.startsWith(`${prefix}/`)) continue;
      const rest = prefix ? dir.slice(prefix.length + 1) : dir;
      if (rest && !rest.includes('/')) folders.add(rest);
    }
    for (const file of files) {
      if (prefix && !file.startsWith(`${prefix}/`)) continue;
      const rest = prefix ? file.slice(prefix.length + 1) : file;
      const cut = rest.indexOf('/');
      if (cut === -1) here.push({ kind: 'file', id: mod.id, file: path.join(mod.dir, ...file.split('/')), label: rest });
      else folders.add(rest.slice(0, cut));
    }
    const made = [...folders].sort().map((name) => ({ kind: 'folder', id: mod.id, mod, files, dirs, prefix: prefix ? `${prefix}/${name}` : name, label: name }));
    return [...made, ...here];
  };

  // What a mod opens into: its scripts, its other files, the mods it uses and the mods that use it.
  const children = (element) => {
    if (element.kind === 'folder') return scriptLevel(element.mod, element.files, element.prefix, element.dirs);
    if (element.kind === 'scripts') return scriptLevel(element.mod, element.files, '', element.dirs);
    if (element.kind === 'assets' || element.kind === 'uses' || element.kind === 'usedby') return element.entries;
    if (element.kind || !element.dir) return [];
    const mod = element;
    const told = describeMod(mod.id, mod.dir) ?? { files: [], dependencies: [] };
    const all = app.listMods();
    const assets = otherFiles(mod.dir).map((file) => {
      const whole = path.join(mod.dir, ...file.split('/'));
      return { kind: 'file', id: mod.id, file: whole, label: file, note: sizeWords(whole) };
    });
    const unreal = unrealFolder(mod.id);
    for (const file of unreal ? otherFiles(unreal) : []) {
      if (UNREAL_ASSET.test(file)) {
        assets.push({ kind: 'file', id: mod.id, file: path.join(unreal, ...file.split('/')), label: file, note: 'in the Unreal project', plain: true });
      }
    }
    const link = (id) => {
      const other = all.find((entry) => entry.id === id);
      return { kind: 'link', id, label: other ? other.name : id, note: other ? (other.version ?? '') : 'not in your mods', missing: !other };
    };
    const uses = (told.dependencies ?? []).map(link);
    const usedBy = all
      .filter((other) => other.id !== mod.id && other.dir && (describeMod(other.id, other.dir)?.dependencies ?? []).includes(mod.id))
      .map((other) => link(other.id));
    const groups = [{ kind: 'scripts', id: mod.id, mod, files: told.files, dirs: folders(mod.dir), label: 'Scripts', note: String(told.files.length) }];
    // game content: the pak the mod brings, where the tools to make one are open
    const pak = path.join(mod.dir, 'content', `${mod.id}.pak`);
    const tools = app.content && app.content.workspace();
    if (tools || fs.existsSync(pak) || unreal) {
      const note = fs.existsSync(pak) ? `${mod.id}.pak, ${sizeWords(pak)}` : unreal ? 'assets, not built yet' : 'none yet';
      groups.push({ kind: 'content', id: mod.id, label: 'Game content', note });
    }
    // always there, so that Add Asset has a place to be pressed
    groups.push({ kind: 'assets', id: mod.id, entries: assets, label: 'Assets', note: assets.length ? String(assets.length) : 'none yet' });
    if (uses.length) groups.push({ kind: 'uses', id: mod.id, entries: uses, label: 'Uses', note: String(uses.length) });
    if (usedBy.length) groups.push({ kind: 'usedby', id: mod.id, entries: usedBy, label: 'Used by', note: String(usedBy.length) });
    return groups;
  };

  const GROUP_ICONS = { scripts: 'file-code', assets: 'file-media', content: 'package', uses: 'references', usedby: 'call-incoming' };

  const childItem = (node) => {
    if (node.kind === 'file') {
      const item = new vscode.TreeItem(node.label, vscode.TreeItemCollapsibleState.None);
      item.resourceUri = vscode.Uri.file(node.file);
      item.description = node.note || undefined;
      item.tooltip = node.file;
      item.contextValue = 'part.file';
      if (!node.plain) item.command = { command: 'vscode.open', title: 'Open', arguments: [item.resourceUri] };
      return item;
    }
    if (node.kind === 'link') {
      const item = new vscode.TreeItem(node.label, vscode.TreeItemCollapsibleState.None);
      item.description = node.note || undefined;
      item.iconPath = new vscode.ThemeIcon(node.missing ? 'warning' : 'package');
      item.contextValue = 'part.link';
      if (!node.missing) item.command = { command: 'wax.openMod', title: 'Open Mod', arguments: [{ id: node.id }] };
      return item;
    }
    const empty = node.kind === 'content' || (node.kind === 'assets' && node.entries.length === 0);
    const state = empty ? vscode.TreeItemCollapsibleState.None
      : node.kind === 'scripts' ? vscode.TreeItemCollapsibleState.Expanded : vscode.TreeItemCollapsibleState.Collapsed;
    const item = new vscode.TreeItem(node.label, state);
    item.description = node.note || undefined;
    item.iconPath = new vscode.ThemeIcon(node.kind === 'folder' ? 'folder' : GROUP_ICONS[node.kind]);
    item.contextValue = node.kind === 'scripts' || node.kind === 'folder' ? 'part.scripts' : node.kind === 'assets' ? 'part.assets' : node.kind === 'content' ? 'part.content' : 'part.group';
    return item;
  };

  const provider = {
    onDidChangeTreeData: changed.event,
    getChildren: (element) => (element ? children(element) : app.listMods()),
    getTreeItem: (mod) => {
      if (mod.kind) return childItem(mod);
      const item = new vscode.TreeItem(mod.name, mod.dir ? vscode.TreeItemCollapsibleState.Collapsed : vscode.TreeItemCollapsibleState.None);
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
    if (game.connected || game.state === 'unset') view.message = undefined;
    else if (game.state === 'devoff') view.message = 'Developer mode is off, so the game does not tell the editor about its mods. These are the mods on disk.';
    else view.message = 'The game is not running. These are the mods on disk.';
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

  // A new folder in a mod: at its top, or inside the folder that was pressed.
  app.command('wax.newFolder', async (arg) => {
    const mod = await app.pickMod(arg, 'Add a folder to which mod?');
    if (!mod || !mod.dir) return;
    const inside = arg && arg.kind === 'folder' ? arg.prefix : '';
    const name = await vscode.window.showInputBox({
      title: inside ? `New Folder in ${mod.id}/${inside}` : `New Folder in ${mod.id}`,
      prompt: 'Name the folder. Letters, digits, - and _.',
      placeHolder: 'extras',
      validateInput: (value) => {
        if (!FOLDER_NAME.test(value ?? '')) return 'Use letters, digits, - and _ only.';
        if (fs.existsSync(path.join(mod.dir, ...inside.split('/').filter(Boolean), value))) return 'There is already something of that name.';
        return undefined;
      },
    });
    if (name === undefined || !FOLDER_NAME.test(name)) return;
    fs.mkdirSync(path.join(mod.dir, ...inside.split('/').filter(Boolean), name), { recursive: true });
    app.scanned = null;
    refresh();
  });

  // Copies files picked on this PC into a mod: pictures, sounds, data. A file of the same name is asked about first.
  app.command('wax.addAsset', async (arg) => {
    const mod = await app.pickMod(arg, 'Add files to which mod?');
    if (!mod || !mod.dir) return;
    const inside = arg && arg.kind === 'folder' ? arg.prefix.split('/') : [];
    const picked = await vscode.window.showOpenDialog({
      title: `Add files to ${mod.id}`, openLabel: 'Add to Mod', canSelectMany: true, canSelectFiles: true, canSelectFolders: false,
      filters: { 'Pictures, sounds and data': [...ASSET_KINDS].map((kind) => kind.slice(1)), 'All files': ['*'] },
    });
    if (!picked || !picked.length) return;
    const target = path.join(mod.dir, ...inside);
    fs.mkdirSync(target, { recursive: true });
    let added = 0;
    const odd = [];
    for (const uri of picked) {
      const name = path.basename(uri.fsPath);
      const to = path.join(target, name);
      if (path.resolve(uri.fsPath) === path.resolve(to)) continue;
      if (fs.existsSync(to)) {
        const replace = 'Replace';
        const choice = await vscode.window.showWarningMessage(`${mod.id} already has ${name}. Replace it?`, { modal: true }, replace);
        if (choice !== replace) continue;
      }
      fs.copyFileSync(uri.fsPath, to);
      added += 1;
      if (!ASSET_KINDS.has(path.extname(name).toLowerCase()) && !name.endsWith('.lua')) odd.push(name);
    }
    app.scanned = null;
    refresh();
    if (odd.length) {
      vscode.window.showWarningMessage(`Wax: added, but the mod catalogue does not take this kind of file: ${odd.join(', ')}. The mod works here and cannot be published with it.`);
    } else if (added) {
      vscode.window.setStatusBarMessage(`$(check) Wax: ${added} file${added === 1 ? '' : 's'} added to ${mod.id}`, 4000);
    }
  });

  // Copies a 3D model (.obj) into the mod's models folder and shows the line of Lua that loads it.
  app.command('wax.addModel', async (arg) => {
    const mod = await app.pickMod(arg, 'Add a 3D model to which mod?');
    if (!mod || !mod.dir) return;
    const picked = await vscode.window.showOpenDialog({
      title: `Add a 3D model to ${mod.id}`, openLabel: 'Add to Mod', canSelectMany: true, canSelectFiles: true, canSelectFolders: false,
      filters: { '3D models (.obj)': ['obj'] },
    });
    if (!picked || !picked.length) return;
    const target = path.join(mod.dir, 'models');
    fs.mkdirSync(target, { recursive: true });
    const names = [];
    for (const uri of picked) {
      const name = path.basename(uri.fsPath);
      if (path.extname(name).toLowerCase() !== '.obj') {
        vscode.window.showWarningMessage(`Wax: ${name} is not an .obj file. Save the model as Wavefront .obj from your 3D program.`);
        continue;
      }
      const to = path.join(target, name);
      if (fs.existsSync(to) && path.resolve(uri.fsPath) !== path.resolve(to)) {
        const replace = 'Replace';
        const choice = await vscode.window.showWarningMessage(`${mod.id} already has models/${name}. Replace it?`, { modal: true }, replace);
        if (choice !== replace) continue;
      }
      if (path.resolve(uri.fsPath) !== path.resolve(to)) fs.copyFileSync(uri.fsPath, to);
      names.push(name);
    }
    app.scanned = null;
    refresh();
    if (!names.length) return;
    const line = `local shape = game.Assets:Model("models/${names[0]}")`;
    const copy = 'Copy the Lua';
    const choice = await vscode.window.showInformationMessage(`Wax: added to ${mod.id}/models. Load it with: ${line}`, copy);
    if (choice === copy && vscode.env.clipboard) await vscode.env.clipboard.writeText(line);
  });

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
