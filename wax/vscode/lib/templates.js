'use strict';
// What a new mod and a new module file start out as
const fs = require('node:fs');
const path = require('node:path');
const { luaString } = require('./luatext');
const names = require('./names');

// What init.lua can start as, in the order New Mod offers them.
const STARTS = [
  { id: 'empty', label: 'Empty', detail: 'One line that prints to the log.' },
  { id: 'window', label: 'Window with a button', detail: 'A window in the menu (F8). The button shows a message.' },
  { id: 'overlay', label: 'Overlay', detail: 'A panel that stays on screen while you play. It shows the map you are on.' },
];

const oneLine = (text) => String(text ?? '').replace(/\s+/g, ' ').trim();

function manifestText(name, description = '') {
  const about = oneLine(description);
  return `return {
    name = ${luaString(oneLine(name))},
${about ? `    description = ${luaString(about)},\n` : ''}    version = "0.1.0",
}
`;
}

const BODIES = {
  empty: ({ title }) => `print(${luaString(`${title} loaded`)})
`,

  window: ({ id, title }) => `-- A window shows in the menu. F8 opens the menu.
local window = ui.Window({ title = ${luaString(title)}, width = 320, height = 200 })
window:Label("Change ${id}/init.lua and save it. This window updates while the game runs.", { dim = true })
window:Button("Say hello", function()
    ui.Notify(${luaString(`Hello from ${title}`)}, { kind = "good" })
end, { primary = true })
`,

  overlay: ({ title }) => `-- An overlay stays on screen while you play. It never takes the mouse.
local overlay = ui.Overlay({ title = ${luaString(title)}, anchor = "top-right" })
local map = overlay:Field("Map", game.MapName or "none")

-- This runs when you enter or leave a prospect.
game.MapChanged:Connect(function(name)
    map:Set(name)
end)
`,
};

// init.lua for a new mod. start is the id of one of STARTS.
function initText(id, name, start = 'window') {
  if (!Object.hasOwn(BODIES, start)) throw new Error(`There is no starting point called "${start}".`);
  const title = oneLine(name);
  return `-- ${title}. This file runs when the mod loads, and again each time you save it.

${BODIES[start]({ id, title })}`;
}

function moduleText(moduleName) {
  const table = names.identifierFor(moduleName);
  return `-- Use it from another file of this mod with: local ${table} = ${names.requireText(moduleName)}
local ${table} = {}

function ${table}.hello()
    print("hello from ${moduleName}")
end

return ${table}
`;
}

// Creates <modsDir>/<Id>/mod.lua and init.lua. Throws before it would touch a folder that is already there.
function createMod(modsDir, name, { description = '', start = 'window' } = {}) {
  const existing = fs.existsSync(modsDir) ? fs.readdirSync(modsDir) : [];
  const problem = names.modNameProblem(name, existing);
  if (problem) throw new Error(problem);
  const id = names.modIdFrom(name);
  const manifestBody = manifestText(name, description);
  const initBody = initText(id, name, start);
  const dir = path.join(modsDir, id);
  fs.mkdirSync(modsDir, { recursive: true });
  fs.mkdirSync(dir);
  const manifest = path.join(dir, 'mod.lua');
  const init = path.join(dir, 'init.lua');
  fs.writeFileSync(manifest, manifestBody, { flag: 'wx' });
  fs.writeFileSync(init, initBody, { flag: 'wx' });
  return { id, dir, manifest, init, start };
}

// Creates one module file in a mod. files: the mod's files, as "sub/util.lua". Never overwrites.
function createModule(modDir, input, files = []) {
  const problem = names.moduleNameProblem(input, files);
  if (problem) throw new Error(problem);
  const parsed = names.parseModuleName(input);
  const file = path.join(modDir, ...parsed.segments) + '.lua';
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, moduleText(parsed.name), { flag: 'wx' });
  return { name: parsed.name, file };
}

module.exports = { STARTS, manifestText, initText, moduleText, createMod, createModule };
