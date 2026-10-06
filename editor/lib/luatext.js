'use strict';
// Small helpers for reading and writing Lua source as text

function longBracketLevel(text, at) {
  if (text[at] !== '[') return -1;
  let j = at + 1;
  while (text[j] === '=') j++;
  return text[j] === '[' ? j - at - 1 : -1;
}

function longBracketEnd(text, from, level) {
  const close = ']' + '='.repeat(level) + ']';
  const end = text.indexOf(close, from);
  return end === -1 ? text.length : end + close.length;
}

// Blanks out comments (and string contents when asked) with spaces, so offsets and line numbers stay the same.
function mask(text, { strings = false } = {}) {
  const out = text.split('');
  const blank = (from, to) => {
    for (let k = from; k < to; k++) if (out[k] !== '\n' && out[k] !== '\r') out[k] = ' ';
  };
  const n = text.length;
  let i = 0;
  while (i < n) {
    const c = text[i];
    if (c === '-' && text[i + 1] === '-') {
      const level = longBracketLevel(text, i + 2);
      let end;
      if (level >= 0) {
        end = longBracketEnd(text, i + 4 + level, level);
      } else {
        end = text.indexOf('\n', i);
        if (end === -1) end = n;
      }
      blank(i, end);
      i = end;
    } else if (c === '"' || c === "'") {
      let j = i + 1;
      while (j < n && text[j] !== c && text[j] !== '\n') j += text[j] === '\\' ? 2 : 1;
      if (strings) blank(i + 1, Math.min(j, n));
      i = Math.min(n, j + 1);
    } else if (c === '[' && longBracketLevel(text, i) >= 0) {
      const level = longBracketLevel(text, i);
      const end = longBracketEnd(text, i + 2 + level, level);
      if (strings) blank(i + 2 + level, Math.max(i + 2 + level, end - 2 - level));
      i = end;
    } else {
      i++;
    }
  }
  return out.join('');
}

// A Lua string literal holding exactly this text.
function luaString(text) {
  const escapes = { '\\': '\\\\', '"': '\\"', '\n': '\\n', '\r': '\\r', '\0': '\\x00' };
  return '"' + String(text).replace(/[\\"\n\r\0]/g, (c) => escapes[c]) + '"';
}

// A Lua literal for a string, number, boolean or nothing.
function luaValue(value) {
  if (value === null || value === undefined) return 'nil';
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new Error(`cannot send ${value} to Lua`);
    return String(value);
  }
  if (typeof value === 'string') return luaString(value);
  throw new Error(`cannot send a ${typeof value} to Lua`);
}

module.exports = { mask, luaString, luaValue };
