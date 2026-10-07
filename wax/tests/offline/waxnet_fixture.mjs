// Makes what waxnet_test.lua tries signatures with: two keys that exist only while this runs, a list, and its signatures.
// Prints the public half of the first key, which scripts\Build-WaxNative.ps1 -SigningTest builds the test copy of the helper with.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const dir = process.argv[2];
if (!dir) {
  console.error('Give the folder to write to.');
  process.exit(1);
}

const half = (text) => Buffer.from(text, 'base64url').toString('hex').padStart(64, '0');
const publicHex = (key) => {
  const jwk = key.export({ format: 'jwk' });
  return half(jwk.x) + half(jwk.y);
};
const sign = (key, text) => crypto.sign('sha256', Buffer.from(text, 'utf8'), { key, dsaEncoding: 'ieee-p1363' }).toString('base64');

const owner = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const other = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const list = 'wax 0.2.1\n'
  + `${'0123456789abcdef'.repeat(4)} 1234 Scripts/main.lua\n`
  + 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 0 Scripts/wax/boot.lua\n'
  + `${'a'.repeat(64)} 7 VERSION\n`
  + `${'d'.repeat(64)} 10 Wax-Import.ps1\n`
  + `${'b'.repeat(64)} 412 assets/lucide/32/arrow up.png\n`
  + `${'c'.repeat(64)} 63345 bin/waxnet.dll\n`;

const out = path.join(dir, 'fixture');
fs.mkdirSync(out, { recursive: true });
fs.writeFileSync(path.join(out, 'list.txt'), list);
fs.writeFileSync(path.join(out, 'good.sig'), `${sign(owner.privateKey, list)}\n`);
fs.writeFileSync(path.join(out, 'other.sig'), `${sign(other.privateKey, list)}\n`);
fs.writeFileSync(path.join(out, 'empty.sig'), `${sign(owner.privateKey, '')}\n`);
fs.writeFileSync(path.join(out, 'key.txt'), publicHex(owner.publicKey));
console.log(publicHex(owner.publicKey));
