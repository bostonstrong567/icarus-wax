// Helper for Test-WaxImport.ps1: stands in for the mod catalogue, and writes zips a real tool would refuse to make.
//   node import-stand-in.mjs serve <cases.json> <folder>   writes port.txt, key.txt and requests.log into the folder
//   node import-stand-in.mjs zip <spec.json>               spec: { zips: [{ out, entries: [{ name, text, ... }] }] }
// cases.json maps a lower-case id to what the catalogue says about that mod. It is read again for every request.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import crypto from 'node:crypto';

const [command, first, second] = process.argv.slice(2);

function makeZip(entries, comment = '') {
  const body = [];
  const directory = [];
  let offset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.name, 'latin1');
    const localName = Buffer.from(entry.localName ?? entry.name, 'latin1');
    const data = entry.zeros ? Buffer.alloc(entry.zeros) : Buffer.from(entry.text ?? '', 'utf8');
    const method = entry.method ?? (data.length > 0 ? 8 : 0);
    const packed = method === 8 ? zlib.deflateRawSync(data, { level: 9 }) : data;
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(entry.flags ?? 0x0800, 6);
    local.writeUInt16LE(method, 8);
    local.writeUInt16LE(0x21, 12);
    local.writeUInt32LE(zlib.crc32(data), 14);
    local.writeUInt32LE(packed.length, 18);
    local.writeUInt32LE(entry.declared ?? data.length, 22);
    local.writeUInt16LE(localName.length, 26);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(entry.madeBy ?? 20, 4);
    local.copy(central, 6, 4, 30);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt32LE((entry.attributes ?? 0) >>> 0, 38);
    central.writeUInt32LE(offset, 42);
    body.push(local, localName, packed);
    directory.push(central, name);
    offset += 30 + localName.length + packed.length;
  }
  const note = Buffer.from(comment, 'latin1');
  const directorySize = directory.reduce((sum, part) => sum + part.length, 0);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(directorySize, 12);
  end.writeUInt32LE(offset, 16);
  end.writeUInt16LE(note.length, 20);
  return Buffer.concat([...body, ...directory, end, note]);
}

function zip() {
  const spec = JSON.parse(fs.readFileSync(first, 'utf8'));
  for (const one of spec.zips) {
    fs.mkdirSync(path.dirname(one.out), { recursive: true });
    fs.writeFileSync(one.out, makeZip(one.entries, one.comment));
  }
}

const half = (text) => Buffer.from(text, 'base64url').toString('hex').padStart(64, '0');

function makeKey() {
  const pair = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const jwk = pair.publicKey.export({ format: 'jwk' });
  return { key: pair.privateKey, hex: half(jwk.x) + half(jwk.y) };
}

// 64 bytes, r then s, in base64: what the owner's tool writes.
const sign = (text, key) => crypto.sign('sha256', Buffer.from(text, 'utf8'), { key, dsaEncoding: 'ieee-p1363' }).toString('base64');

function serve() {
  const folder = second;
  const own = makeKey();
  const other = makeKey();
  const requests = path.join(folder, 'requests.log');
  fs.mkdirSync(folder, { recursive: true });
  fs.writeFileSync(requests, '');
  fs.writeFileSync(path.join(folder, 'key.txt'), own.hex);

  const json = (res, status, value) => {
    const text = typeof value === 'string' ? value : JSON.stringify(value);
    res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text) });
    res.end(text);
  };

  const server = http.createServer((req, res) => {
    res.on('error', () => {});
    fs.appendFileSync(requests, `${req.method} ${req.url}\n`);
    const cases = JSON.parse(fs.readFileSync(first, 'utf8'));
    const match = /^\/api\/mods\/([^/]+)(?:\/download\/([^/]+))?$/.exec(req.url);
    const found = match && cases[match[1].toLowerCase()];
    if (!found) return json(res, 404, { error: 'There is no such mod.' });
    if (found.status) return json(res, found.status, { error: 'no' });

    if (match[2] === undefined) {
      if (found.entryRaw !== undefined) return json(res, 200, found.entryRaw);
      const about = { id: found.entryId ?? found.id, name: found.name, summary: 'A mod for the tests.', author: found.author };
      if (found.version !== undefined) about.latest = { version: found.version, size: 1, download: `/api/mods/${found.id}/download/${found.version}` };
      return json(res, 200, about);
    }

    if (match[2] !== found.version) return json(res, 404, { error: `${found.id} has no such version.` });
    if (found.redirect) {
      res.writeHead(302, { location: found.redirect });
      return res.end();
    }
    const bytes = found.zeros ? Buffer.alloc(found.zeros) : fs.readFileSync(found.zip);
    const sum = crypto.createHash('sha256').update(bytes).digest('hex');
    const text = (kind, id, version) => `${kind} ${id} ${version}\n${sum} ${bytes.length}\n`;
    const good = sign(text('zip', found.id, found.version), own.key);
    const signature = {
      good,
      none: null,
      bad: good.replace(/^./, good[0] === 'A' ? 'B' : 'A'),
      garbage: 'not a signature',
      version: sign(text('zip', found.id, '9.9.9'), own.key),
      id: sign(text('zip', 'Another', found.version), own.key),
      kind: sign(text('mod', found.id, found.version), own.key),
      key: sign(text('zip', found.id, found.version), other.key),
    }[found.signature ?? 'good'];
    const headers = { 'content-type': 'application/zip', 'X-Checksum-Sha256': sum, connection: 'close' };
    if (signature) headers['X-Wax-Signature'] = signature;
    const length = found.length ?? 'true';
    if (length === 'true') headers['content-length'] = bytes.length;
    else if (length !== 'none') headers['content-length'] = Number(length);
    res.writeHead(200, headers);
    if (length !== 'none') return res.end(bytes);
    for (let at = 0; at < bytes.length; at += 1 << 20) res.write(bytes.subarray(at, at + (1 << 20)));
    return res.end();
  });

  server.on('clientError', (error, socket) => socket.destroy());
  server.listen(0, '127.0.0.1', () => fs.writeFileSync(path.join(folder, 'port.txt'), String(server.address().port)));
}

if (command === 'zip') zip();
else if (command === 'serve') serve();
else {
  console.error('usage: node import-stand-in.mjs serve <cases.json> <folder> | zip <spec.json>');
  process.exit(2);
}
