// Prints a live test reply ({ passed, failed, details }) in readable form. Usage: node show.mjs <reply.json>
import fs from 'node:fs';
const reply = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!reply.ok) { console.log('EVAL ERROR:', reply.error); process.exit(1); }
const value = reply.values[0];
for (const line of Array.isArray(value.details) ? value.details : []) console.log(line);
console.log(`passed ${value.passed}, failed ${value.failed}`, value.stats ? JSON.stringify(value.stats) : '');
process.exit(value.failed ? 1 : 0);
