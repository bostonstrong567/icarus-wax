// Stands in for GitHub in Test-WaxRelease.ps1: the "newest release" answer and the files of that release.
// Usage: node serve.mjs <folder> <port file> <installed version>
// <folder>/case.txt names what to play next. <folder>/files holds Wax-9.9.9.zip and old-inside.zip.
// It makes its own key pair, writes the public half to <folder>/key.txt and every request to <folder>/requests.log.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const [folder, portFile, current] = process.argv.slice(2);
const own = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const other = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const half = (text) => Buffer.from(text, 'base64url').toString('hex').padStart(64, '0');
const jwk = own.publicKey.export({ format: 'jwk' });
fs.writeFileSync(path.join(folder, 'key.txt'), half(jwk.x) + half(jwk.y));

const sha256 = (data) => crypto.createHash('sha256').update(data).digest('hex');
const signed = (text, pair) => `${crypto.sign('sha256', Buffer.from(text, 'utf8'), { key: pair.privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64')}\n`;
const log = (line) => fs.appendFileSync(path.join(folder, 'requests.log'), `${line}\n`);
const vsix = Buffer.from('a stand-in for the extension');

// The signed list as the owner's tool writes it: "release <version>", then "<sha256> <size> <name>" by name, each line ended by a line feed.
function listText(version, files, pad) {
  const all = [...files];
  for (let i = 0; pad && i < 1500; i++) all.push({ name: `filler-${String(i).padStart(4, '0')}.bin`, data: Buffer.from(String(i)) });
  const lines = all.map((file) => ({ name: Buffer.from(file.name, 'utf8'), line: `${sha256(file.data)} ${file.data.length} ${file.name}\n` }));
  lines.sort((a, b) => Buffer.compare(a.name, b.name));
  return `release ${version}\n${lines.map((entry) => entry.line).join('')}`;
}

// What one case plays. Every case starts from a good release of 9.9.9 and changes one thing.
function scene(name, base, port) {
  const s = { status: 200, tag: 'v9.9.9', version: '9.9.9', assets: ['zip', 'list', 'sig'], listVersion: null, key: own, signedText: null, signature: null,
    zipFile: 'Wax-9.9.9.zip', send: 'whole', pad: false, hop: null, address: (file) => `${base}/dl/v9.9.9/${file}` };
  const cases = {
    none: () => { s.status = 404; },
    limit: () => { s.status = 403; },
    same: () => { s.tag = `v${current}`; s.version = current; s.address = (file) => `${base}/dl/v${current}/${file}`; },
    older: () => { s.tag = 'v0.0.1'; s.version = '0.0.1'; s.address = (file) => `${base}/dl/v0.0.1/${file}`; },
    oddtag: () => { s.tag = 'nightly'; },
    noasset: () => { s.assets = []; },
    unsigned: () => { s.assets = ['zip']; },
    nosig: () => { s.assets = ['zip', 'list']; },
    'elsewhere-path': () => { s.address = (file) => `${base}/elsewhere/v9.9.9/${file}`; },
    'elsewhere-host': () => { s.address = (file) => `http://localhost:${port}/dl/v9.9.9/${file}`; },
    'elsewhere-dots': () => { s.address = (file) => `${base}/dl/v9.9.9/../../elsewhere/${file}`; },
    'elsewhere-user': () => { s.address = (file) => `http://127.0.0.1:${port}@example.invalid/dl/v9.9.9/${file}`; },
    'elsewhere-tag': () => { s.address = (file) => `${base}/dl/v9.9.8/${file}`; },
    'elsewhere-query': () => { s.address = (file) => `${base}/dl/v9.9.9/${file}?from=elsewhere`; },
    'elsewhere-list': () => { s.address = (file) => (file.endsWith('.manifest') ? `${base}/elsewhere/${file}` : `${base}/dl/v9.9.9/${file}`); },
    badsig: () => { s.signedText = 'release 9.9.9\n'; },
    otherkey: () => { s.key = other; },
    notsig: () => { s.signature = 'this is not a signature\n'; },
    biglist: () => { s.pad = true; },
    otherversion: () => { s.listVersion = '9.9.8'; },
    changedzip: () => { s.send = 'changed'; },
    smaller: () => { s.send = 'smaller'; },
    bigger: () => { s.send = 'bigger'; },
    bigheader: () => { s.send = 'bigheader'; },
    broken: () => { s.send = 'gone'; },
    notwax: () => { s.zipFile = null; },
    oldinside: () => { s.zipFile = 'old-inside.zip'; },
    redirect: () => { s.hop = (file) => `/cdn/${file}`; },
    'redirect-kind': () => { s.hop = (file) => `https://127.0.0.1:${port}/cdn/${file}`; },
    'redirect-loop': () => { s.hop = (file) => `/dl/v9.9.9/${file}`; },
    new: () => {},
  };
  (cases[name] ?? cases.none)();
  return s;
}

const server = http.createServer((req, res) => {
  try {
    answer(req, res);
  } catch (error) {
    log(`error ${error.message}`);
    res.writeHead(500);
    res.end();
  }
});

function answer(req, res) {
  const { port } = server.address();
  const base = `http://127.0.0.1:${port}`;
  let name = 'none';
  try {
    name = fs.readFileSync(path.join(folder, 'case.txt'), 'utf8').trim();
  } catch {}
  log(`${name} ${req.method} ${req.url}`);
  const s = scene(name, base, port);
  const send = (code, type, body) => {
    res.writeHead(code, { 'content-type': type, 'content-length': body.length });
    res.end(body);
  };
  const names = { zip: `Wax-${s.version}.zip`, list: `Wax-${s.version}.manifest`, sig: `Wax-${s.version}.manifest.sig` };

  if (req.url === '/api/latest') {
    if (s.status !== 200) return send(s.status, 'application/json', Buffer.from(JSON.stringify({ message: s.status === 404 ? 'Not Found' : 'API rate limit exceeded' })));
    const assets = [{ name: 'wax-icarus-9.9.9.vsix', browser_download_url: `${base}/dl/${s.tag}/wax-icarus-9.9.9.vsix` }];
    for (const kind of s.assets) assets.push({ name: names[kind], browser_download_url: s.address(names[kind]) });
    return send(200, 'application/json', Buffer.from(JSON.stringify({ tag_name: s.tag, assets })));
  }

  const asked = /^\/(dl\/v[0-9.]+|cdn)\/([A-Za-z0-9._-]+)$/.exec(req.url);
  if (!asked) return send(404, 'text/plain', Buffer.from('not here'));
  const file = asked[2];
  if (s.hop && (asked[1] !== 'cdn' || name === 'redirect-loop')) {
    res.writeHead(302, { location: s.hop(file), 'content-length': 0 });
    return res.end();
  }
  const zip = s.zipFile ? fs.readFileSync(path.join(folder, 'files', s.zipFile)) : Buffer.from('this is not a zip');
  const text = listText(s.listVersion ?? s.version, [{ name: names.zip, data: zip }, { name: 'wax-icarus-9.9.9.vsix', data: vsix }], s.pad);
  if (file === names.list) return send(200, 'application/octet-stream', Buffer.from(text, 'utf8'));
  if (file === names.sig) return send(200, 'application/octet-stream', Buffer.from(s.signature ?? signed(s.signedText ?? text, s.key), 'utf8'));
  if (file === 'wax-icarus-9.9.9.vsix') return send(200, 'application/octet-stream', vsix);
  if (file !== names.zip || s.send === 'gone') return send(404, 'text/plain', Buffer.from('not here'));

  if (s.send === 'changed') {
    const changed = Buffer.from(zip);
    changed[changed.length >> 1] ^= 1;
    return send(200, 'application/zip', changed);
  }
  if (s.send === 'smaller') return send(200, 'application/zip', zip.subarray(0, zip.length - 1000));
  if (s.send === 'bigheader') return send(200, 'application/zip', Buffer.concat([zip, Buffer.alloc(1000)]));
  if (s.send === 'bigger') {
    // No length is given, and more keeps coming until the reader hangs up or 64 MB of extra went out.
    const chunk = Buffer.alloc(65536, 7);
    let extra = 0;
    let open = true;
    res.on('close', () => { open = false; log(`${name} extra ${extra}`); });
    res.writeHead(200, { 'content-type': 'application/zip' });
    res.write(zip);
    const more = () => {
      while (open && extra < 64 * 1024 * 1024) {
        extra += chunk.length;
        if (!res.write(chunk)) return res.once('drain', more);
      }
      if (open) res.end();
    };
    return more();
  }
  return send(200, 'application/zip', zip);
}

server.listen(0, '127.0.0.1', () => fs.writeFileSync(portFile, String(server.address().port)));
