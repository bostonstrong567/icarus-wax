// Stress test: switch themes and accents, rebuild pages and reload mods over and over, forcing the engine to free
// unused objects in between. A widget touched after it was freed crashes the game, so surviving this is the test.
// The theme, accent and page the player had are put back at the end.
//   node wax/tests/live/theme_stress.mjs [rounds]
import fs from 'node:fs';
import path from 'node:path';
import { ROOT, crashFolders, evalLua, gameRunning, sleep } from '../../cli/bridge.mjs';

const rounds = Number(process.argv[2] ?? 6);
const stepFile = fs.readFileSync(path.join(ROOT, 'wax', 'tests', 'live', 'theme_stress_step.lua'), 'utf8');
const crashesBefore = crashFolders();
const themes = ['Dune', 'Graphite', 'Daylight', 'Abyss', 'Midnight'];
const accents = ['Teal', 'Pink', 'From the theme', 'Amber', 'Blue'];
let steps = 0;
let last;

async function step(action, value) {
  const literal = value === undefined ? 'nil' : JSON.stringify(value);
  const reply = await evalLua(`WaxStress = { action = ${JSON.stringify(action)}, value = ${literal} }\n${stepFile}`, { timeoutSec: 20 });
  if (!reply.ok) throw new Error(`${action} ${value ?? ''}: ${reply.error}`);
  return reply.values[0];
}

async function run(action, value, waitMs = 250) {
  last = await step(action, value);
  steps++;
  if (Array.isArray(last.errors) && last.errors.length) throw new Error(`${action} ${value ?? ''}: Lua errors: ${last.errors.join(' | ')}`);
  await sleep(waitMs);
}

const startedOpen = (await evalLua('return Wax.ui.IsOpen()')).values?.[0] === true;
const before = await step('state');
let failure = null;
try {
  await evalLua('Wax.guard.clear_errors() return true');
  await run('open');
  for (let round = 0; round < rounds; round++) {
    await run('page', 'Settings');
    await run('pick', themes[round % themes.length], 400);
    if (!last.open) throw new Error('the menu closed during a theme switch');
    await run('collect', undefined, 700);
    await run('pick', accents[round % accents.length], 300);
    await run('reload', undefined, 700);
    await run('notify', round, 200);
    await run('page', 'Icons');
    await run('icons', ['arrow', 'map', 'user', 'file', 'x'][round % 5], 600);
    await run('collect', undefined, 700);
    await run('page', 'Performance');
    await run('pick', themes[(round + 2) % themes.length], 400);
    await run('collect', undefined, 1500);
    await run('pick', themes[(round + 3) % themes.length], 300);
    console.log(`round ${round + 1}/${rounds}: theme ${last.theme}, ${last.windows} windows, ${last.handlers} handlers, ${last.painted} colours remembered, menu ${last.open ? 'open' : 'CLOSED'}`);
  }
} catch (error) {
  failure = error.message;
} finally {
  if (gameRunning()) {
    await step('icons', '').catch(() => {});
    await sleep(300);
    await step('pick', before.accent).catch(() => {});
    await step('pick', before.theme).catch(() => {});
    await sleep(300);
    if (before.page) await step('page', before.page).catch(() => {});
    if (!startedOpen) await evalLua('Wax.ui.Close() return true').catch(() => {});
    last = await step('state').catch(() => last);
  }
}
const result = { ok: !failure && gameRunning() && crashFolders() === crashesBefore, steps, failure, gameStillRunning: gameRunning(),
  newCrashReports: crashFolders() - crashesBefore, before: { theme: before.theme, accent: before.accent, page: before.page }, last };
console.log(JSON.stringify(result, null, 2));
process.exit(result.ok ? 0 : 1);
