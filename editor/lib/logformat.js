'use strict';
// How a line of the game's log looks in the output channel

function clock(seconds) {
  const date = seconds ? new Date(seconds * 1000) : new Date();
  return [date.getHours(), date.getMinutes(), date.getSeconds()].map((n) => String(n).padStart(2, '0')).join(':');
}

const firstLine = (text) => String(text ?? '').split(/\r?\n/)[0];

// "02:44:12 [error] [Hello] message", with the lines of a traceback indented under it.
function formatEntry(entry) {
  const lines = String(entry.message ?? '').split(/\r?\n/);
  const times = entry.count > 1 ? ` (x${entry.count})` : '';
  const head = `${clock(entry.time)} [${entry.level}] [${entry.channel}]${times} ${lines[0]}`;
  // a repeat of a message already shown: the counter is the news, not the traceback
  if (entry.again) return head;
  return [head, ...lines.slice(1).map((line) => '    ' + line.replace(/^\t/, ''))].join('\n');
}

// A traceback without the frames of whatever ran the code (everything from xpcall down).
function trimTrace(trace) {
  const lines = String(trace ?? '').split(/\r?\n/);
  const cut = lines.findIndex((line) => /\[C\]: in function 'xpcall'/.test(line));
  return (cut === -1 ? lines : lines.slice(0, cut)).join('\n');
}

// Where an error from running `chunkname` happened: { line, message }, or null when it does not say.
function locateInChunk(error, chunkname) {
  const lines = String(error ?? '').split(/\r?\n/);
  const name = chunkname.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const direct = new RegExp(`(?:^|[\\s:])${name}:(\\d+): (.*)$`).exec(lines[0]);
  if (direct) return { line: Number(direct[1]), message: direct[2] };
  const frame = new RegExp(`^\\s*${name}:(\\d+): in `);
  for (const line of lines.slice(1)) {
    const match = frame.exec(line);
    if (match) return { line: Number(match[1]), message: lines[0] };
  }
  return null;
}

module.exports = { clock, firstLine, formatEntry, trimTrace, locateInChunk };
