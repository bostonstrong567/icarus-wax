'use strict';
// Turns what the game logs into problems on a mod's file and line (the message shapes are listed in README.md)

const CHUNK = /(?:^|[\s:(])((?:\.\.\.)?(?:[A-Za-z]:)?[^\s:()]+\.lua):(\d+):/g;

const slashes = (text) => text.replace(/\\/g, '/');

// Which mod file a file name in a message means: { mod, file }, or null. mods: [{ id, dir, files }].
function resolveChunk(chunk, mods) {
  const name = slashes(chunk);
  // Lua shortens a long name to "..." and its last characters
  const shortened = name.startsWith('...');
  if (!shortened) {
    const slash = name.indexOf('/');
    const mod = slash > 0 ? mods.find((other) => other.id === name.slice(0, slash)) : null;
    if (mod) return { mod, file: name.slice(slash + 1) };
  }
  const text = (shortened ? name.slice(3) : name).toLowerCase();
  const hits = [];
  for (const mod of mods) {
    for (const file of mod.files) {
      const full = `${slashes(mod.dir)}/${file}`.toLowerCase();
      if (text.endsWith(`/${mod.id}/${file}`.toLowerCase()) || (shortened && full.endsWith(text))) hits.push({ mod, file });
    }
  }
  return hits.length === 1 ? hits[0] : null;
}

// The first place in `text` that names a mod's file and line: { mod, file, line, rest }, or null.
function locate(text, mods) {
  for (const match of text.matchAll(CHUNK)) {
    const found = resolveChunk(match[1], mods);
    if (found) {
      const rest = text.slice(match.index + match[0].length).trim();
      return { mod: found.mod, file: found.file, line: Number(match[2]), rest };
    }
  }
  return null;
}

// One log entry as a problem: { modId, file, line, message, kind: "load" | "runtime" }. Null when it names no mod file.
function parseEntry(entry, mods) {
  if (!entry || entry.level !== 'error' || typeof entry.message !== 'string') return null;
  const lines = entry.message.split(/\r?\n/);
  const first = lines[0];
  const manifest = entry.channel === 'wax.mods' ? /^([\w-]+): mod\.lua: (.*)$/.exec(first) : null;
  if (manifest) {
    const mod = mods.find((other) => other.id === manifest[1]);
    if (!mod) return null;
    const at = /:(\d+): (.*)$/.exec(manifest[2]);
    return { modId: mod.id, file: 'mod.lua', line: at ? Number(at[1]) : 1, message: at ? at[2] : manifest[2], kind: 'load' };
  }
  const kind = /^loading [\w-]+: /.test(first) ? 'load' : 'runtime';
  const direct = locate(first, mods);
  if (direct) return { modId: direct.mod.id, file: direct.file, line: direct.line, message: direct.rest || first, kind };
  // the message itself names something else (a library file); the traceback says which mod line led there
  for (const frame of lines.slice(1)) {
    const found = locate(frame, mods);
    if (found) return { modId: found.mod.id, file: found.file, line: found.line, message: first, kind };
  }
  return null;
}

// The id of the mod a log entry says has just loaded cleanly, or null.
function loadedMod(entry) {
  if (!entry || entry.channel !== 'wax.mods' || entry.level !== 'info') return null;
  const match = /^([\w-]+) .*?loaded in [\d.]+ ms/.exec(String(entry.message));
  return match ? match[1] : null;
}

// A failed mod's one-line error, as the game's mod list gives it.
function parseStatus(mod, mods) {
  if (!mod || mod.status !== 'failed' || !mod.error) return null;
  const text = String(mod.error);
  if (text.startsWith('mod.lua: ')) return parseEntry({ level: 'error', channel: 'wax.mods', message: `${mod.id}: ${text}` }, mods);
  return parseEntry({ level: 'error', channel: mod.id, message: `loading ${mod.id}: ${text}` }, mods);
}

// Keeps the current problems of every mod as log entries and mod lists arrive.
class Tracker {
  constructor() {
    this.byMod = new Map();
  }

  clear(modId) {
    this.byMod.delete(modId);
  }

  add(problem) {
    const list = this.byMod.get(problem.modId) ?? [];
    if (list.some((other) => other.file === problem.file && other.line === problem.line && other.message === problem.message)) return;
    list.push(problem);
    this.byMod.set(problem.modId, list);
  }

  snapshot() {
    return JSON.stringify([...this.byMod]);
  }

  // Log entries, oldest first. Returns true when the problems are not what they were.
  apply(entries, mods) {
    const before = this.snapshot();
    for (const entry of entries) {
      const loaded = loadedMod(entry);
      if (loaded) {
        this.clear(loaded);
        continue;
      }
      const problem = parseEntry(entry, mods);
      if (!problem) continue;
      // a new attempt to load replaces whatever the last one left
      if (problem.kind === 'load') this.clear(problem.modId);
      this.add(problem);
    }
    return this.snapshot() !== before;
  }

  // The game's mod list: catches a failure or a clean load whose log line was not seen.
  sync(list, mods) {
    const before = this.snapshot();
    const known = new Set(list.map((mod) => mod.id));
    for (const id of [...this.byMod.keys()]) {
      if (!known.has(id)) this.clear(id);
    }
    for (const mod of list) {
      const failedBefore = (this.byMod.get(mod.id) ?? []).some((problem) => problem.kind === 'load');
      if (mod.status === 'failed' && !failedBefore) {
        const problem = parseStatus(mod, mods);
        if (problem) this.add(problem);
      } else if ((mod.status === 'loaded' && failedBefore) || mod.status === 'disabled') {
        this.clear(mod.id);
      }
    }
    return this.snapshot() !== before;
  }

  // Every problem with the path of its file: [{ path, modId, file, line, message, kind }]. dirs: id -> folder.
  all(dirs) {
    const out = [];
    for (const [modId, list] of this.byMod) {
      const dir = dirs.get(modId);
      if (!dir) continue;
      for (const problem of list) out.push({ ...problem, path: `${slashes(dir)}/${problem.file}` });
    }
    return out;
  }
}

module.exports = { resolveChunk, locate, parseEntry, loadedMod, parseStatus, Tracker };
