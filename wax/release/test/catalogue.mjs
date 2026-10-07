// Stands in for the mod catalogue in Test-WaxSetup.ps1. Usage: node catalogue.mjs <cases.json> <port file>
// cases.json maps a lower-case id to { id, name, version, zip, checksum: "good" | "bad" | "none", fileVersion }.
import http from 'node:http';
import fs from 'node:fs';
import crypto from 'node:crypto';

const [casesFile, portFile] = process.argv.slice(2);

const server = http.createServer((req, res) => {
  const cases = JSON.parse(fs.readFileSync(casesFile, 'utf8'));
  const match = /^\/api\/mods\/([^/]+)(\/download)?$/.exec(req.url);
  const found = match && cases[match[1].toLowerCase()];
  if (!found) {
    res.writeHead(404, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ error: 'not found' }));
  }
  if (found.status) {
    res.writeHead(found.status, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ error: 'no' }));
  }
  if (!match[2]) {
    res.writeHead(200, { 'content-type': 'application/json' });
    const about = { id: found.id, name: found.name, summary: 'A mod for the tests.' };
    if (found.version) about.latest = { version: found.version, size: 1 };
    return res.end(JSON.stringify(about));
  }
  const bytes = fs.readFileSync(found.zip);
  const headers = { 'content-type': 'application/zip' };
  const sum = crypto.createHash('sha256').update(bytes).digest('hex');
  if (found.checksum === 'good') headers['X-Checksum-Sha256'] = sum;
  if (found.checksum === 'bad') headers['X-Checksum-Sha256'] = sum.replace(/^./, sum[0] === '0' ? '1' : '0');
  if (found.fileVersion) headers['Content-Disposition'] = `attachment; filename="${found.id}-${found.fileVersion}.zip"`;
  res.writeHead(200, headers);
  res.end(bytes);
});

server.listen(0, '127.0.0.1', () => fs.writeFileSync(portFile, String(server.address().port)));
