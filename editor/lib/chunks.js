'use strict';
// The Lua this extension sends to the game lives in ../lua; this turns one of those files into a request
const fs = require('node:fs');
const path = require('node:path');
const { luaValue } = require('./luatext');

const DIR = path.join(__dirname, '..', 'lua');
const cache = new Map();

function body(name) {
  if (!cache.has(name)) cache.set(name, fs.readFileSync(path.join(DIR, `${name}.lua`), 'utf8'));
  return cache.get(name);
}

// The text to send: the named file's code, called with these values as its "...".
function call(name, ...args) {
  return `(function(...)\n${body(name)}\nend)(${args.map(luaValue).join(', ')})`;
}

module.exports = { call, body };
