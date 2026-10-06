// Finding the game, the Wax folder in it and the mods folder
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { require, scratch, put, makeRuntime, makeGame, waxIn, ROOT } from './helpers.mjs';

const paths = require('../lib/paths.js');
const { scanMods, modOf, listLuaFiles, readManifest } = require('../lib/mods.js');

const noSteam = () => [];
const nothing = { dir: null, source: null, game: null, problem: null };
const vdfPath = (dir) => dir.replaceAll('\\', '\\\\');

test('libraryfolders.vdf gives every Steam library', () => {
  const vdf = `"libraryfolders"
{
\t"0"
\t{
\t\t"path"\t\t"C:\\\\Program Files (x86)\\\\Steam"
\t\t"label"\t\t""
\t\t"apps"
\t\t{
\t\t\t"228980"\t\t"412830921"
\t\t}
\t}
\t"1"
\t{
\t\t"path"\t\t"D:\\\\SteamLibrary"
\t\t"apps"
\t\t{
\t\t\t"1149460"\t\t"91837465123"
\t\t}
\t}
}`;
  assert.deepEqual(paths.parseLibraryFolders(vdf), ['C:\\Program Files (x86)\\Steam', 'D:\\SteamLibrary']);
  assert.deepEqual(paths.parseLibraryFolders('nothing here'), []);
});

test('the older libraryfolders.vdf, with the folders as plain values, is read too', () => {
  const vdf = '"LibraryFolders"\n{\n\t"TimeNextStatsReport"\t\t"1612345678"\n\t"ContentStatsID"\t\t"-123456789"\n\t"1"\t\t"D:\\\\Games\\\\Steam"\n\t"2"\t\t"E:/SteamLibrary"\n}\n';
  assert.deepEqual(paths.parseLibraryFolders(vdf), ['D:\\Games\\Steam', 'E:/SteamLibrary']);
});

test('the app manifest gives the game folder name', () => {
  assert.equal(paths.parseInstallDir('"AppState"\n{\n\t"appid"\t\t"1149460"\n\t"installdir"\t\t"Icarus"\n}'), 'Icarus');
  assert.equal(paths.parseInstallDir('"AppState" { }'), null);
});

test('Steam roots come from the registry first, then the usual places, without repeats', () => {
  const env = { 'ProgramFiles(x86)': 'C:\\Program Files (x86)', ProgramFiles: 'C:\\Program Files', ProgramW6432: 'C:\\Program Files' };
  assert.deepEqual(paths.steamRoots(env, () => 'c:\\program files (x86)\\steam'),
    ['c:\\program files (x86)\\steam', 'C:\\Program Files\\Steam']);
  assert.deepEqual(paths.steamRoots(env, () => ['E:\\Steam', 'c:\\program files (x86)\\steam', 'e:\\steam']),
    ['E:\\Steam', 'c:\\program files (x86)\\steam', 'C:\\Program Files\\Steam']);
  assert.deepEqual(paths.steamRoots(env, () => null), ['C:\\Program Files (x86)\\Steam', 'C:\\Program Files\\Steam']);
  assert.deepEqual(paths.steamRoots(env, () => []), ['C:\\Program Files (x86)\\Steam', 'C:\\Program Files\\Steam']);
  assert.deepEqual(paths.steamRoots({}, () => null), []);
});

test('every library is read, from either place Steam keeps the list', (t) => {
  const base = scratch(t);
  const [steam, second, third] = ['Steam', 'Second', 'Third'].map((name) => path.join(base, name));
  put(steam, {
    'steamapps/libraryfolders.vdf': `"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"${vdfPath(steam)}"\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"${vdfPath(second)}"\n\t}\n}\n`,
    'config/libraryfolders.vdf': `"libraryfolders"\n{\n\t"1"\n\t{\n\t\t"path"\t\t"${vdfPath(second)}"\n\t}\n\t"2"\n\t{\n\t\t"path"\t\t"${vdfPath(third)}"\n\t}\n}\n`,
  });
  assert.deepEqual(paths.steamLibraries([steam]), [steam, second, third]);
  assert.deepEqual(paths.steamLibraries([path.join(base, 'missing')]), [path.join(base, 'missing')]);
});

test('the game is found in a Steam library other than the one Steam is installed in', (t) => {
  const base = scratch(t);
  const steam = path.join(base, 'Steam');
  const library = path.join(base, 'Games Library');
  const game = path.join(library, 'steamapps', 'common', 'IcarusGame');
  put(steam, { 'steamapps/libraryfolders.vdf': `"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"${vdfPath(steam)}"\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"${vdfPath(library)}"\n\t}\n}\n` });
  put(library, { 'steamapps/appmanifest_1149460.acf': '"AppState"\n{\n\t"installdir"\t\t"IcarusGame"\n}\n' });
  assert.deepEqual(paths.findSteamGames([steam]), [], 'Steam lists the game but its folder is not there');
  makeGame(game);
  assert.deepEqual(paths.findSteamGames([steam]), [{ game, runtime: null }], 'the game is there but Wax is not installed in it');
  makeRuntime(waxIn(game));
  assert.deepEqual(paths.findSteamGames([steam]), [{ game, runtime: waxIn(game) }]);
  assert.deepEqual(paths.findSteamGames([path.join(base, 'missing')]), []);
});

test('without Steam\'s record of the game, a folder named Icarus counts only when the game is in it', (t) => {
  const steam = path.join(scratch(t), 'Steam');
  const game = path.join(steam, 'steamapps', 'common', 'Icarus');
  fs.mkdirSync(game, { recursive: true });
  assert.deepEqual(paths.findSteamGames([steam]), []);
  makeGame(game);
  assert.deepEqual(paths.findSteamGames([steam]), [{ game, runtime: null }]);
});

test('a folder someone points at may be the game, the Wax folder or one near them', (t) => {
  const base = scratch(t);
  const game = makeGame(path.join(base, 'steamapps', 'common', 'Icarus'));
  const none = { runtime: null, game };
  assert.deepEqual(paths.describeFolder(game), none);
  assert.deepEqual(paths.describeFolder(path.join(game, 'Icarus', 'Binaries', 'Win64')), none);
  assert.deepEqual(paths.describeFolder(path.join(base, 'steamapps', 'common')), none);
  assert.deepEqual(paths.describeFolder(base), none, 'the Steam library the game is in');
  assert.deepEqual(paths.describeFolder(path.join(base, 'elsewhere')), { runtime: null, game: null });

  const runtime = makeRuntime(waxIn(game));
  const both = { runtime, game };
  assert.deepEqual(paths.describeFolder(game), both);
  assert.deepEqual(paths.describeFolder(runtime), both);
  assert.deepEqual(paths.describeFolder(path.join(game, 'Icarus')), both);
  assert.deepEqual(paths.describeFolder(path.join(runtime, 'mods')), both);
  assert.deepEqual(paths.describeFolder(path.join(game, 'Icarus', 'Binaries', 'Win64', 'ue4ss')), both);

  // Wax kept somewhere that is not a game
  const loose = makeRuntime(path.join(base, 'loose', 'Wax'));
  assert.deepEqual(paths.describeFolder(loose), { runtime: loose, game: null });
  const copy = path.join(base, 'copy');
  makeRuntime(waxIn(copy));
  assert.deepEqual(paths.describeFolder(copy), { runtime: waxIn(copy), game: null });
});

test('the Wax folder is looked for in order: the settings, the workspace, a folder that is one, Steam', (t) => {
  const base = scratch(t);
  const fromSetting = makeRuntime(path.join(base, 'setting', 'Wax'));
  const game = makeGame(path.join(base, 'game'));
  const inGame = makeRuntime(waxIn(game));
  const workspace = path.join(base, 'workspace');
  const inWorkspace = makeRuntime(path.join(workspace, 'wax', 'runtime'));
  const itself = makeRuntime(path.join(base, 'itself'));
  const steamGame = makeGame(path.join(base, 'steam', 'Icarus'));
  const fromSteam = makeRuntime(waxIn(steamGame));
  const steam = () => [{ game: steamGame, runtime: fromSteam }];
  const plain = path.join(base, 'plain');
  fs.mkdirSync(plain);

  assert.deepEqual(paths.findRuntime({ runtimePath: fromSetting, gamePath: game, folders: [workspace, itself], steam }),
    { dir: fromSetting, source: 'setting', game: null, problem: null });
  assert.deepEqual(paths.findRuntime({ gamePath: game, folders: [workspace, itself], steam }),
    { dir: inGame, source: 'setting', game, problem: null });
  assert.equal(paths.findRuntime({ runtimePath: '', folders: [itself, workspace], steam }).dir, inWorkspace);
  assert.equal(paths.findRuntime({ folders: [plain, workspace], steam }).source, 'workspace');
  assert.deepEqual(paths.findRuntime({ folders: [plain, itself], steam }), { dir: itself, source: 'folder', game: null, problem: null });
  assert.deepEqual(paths.findRuntime({ folders: [plain], steam }), { dir: fromSteam, source: 'steam', game: steamGame, problem: null });
  assert.deepEqual(paths.findRuntime({ folders: [plain], steam: noSteam }), nothing);
  assert.deepEqual(paths.findRuntime({ steam: noSteam }), nothing);
});

test('each setting takes the game folder or the Wax folder', (t) => {
  const base = scratch(t);
  const game = makeGame(path.join(base, 'Icarus'));
  const runtime = makeRuntime(waxIn(game));
  const found = { dir: runtime, source: 'setting', game, problem: null };
  assert.deepEqual(paths.findRuntime({ gamePath: game, steam: noSteam }), found);
  assert.deepEqual(paths.findRuntime({ gamePath: runtime, steam: noSteam }), found);
  assert.deepEqual(paths.findRuntime({ runtimePath: game, steam: noSteam }), found);
  assert.deepEqual(paths.findRuntime({ runtimePath: runtime, steam: noSteam }), found);
  assert.deepEqual(paths.findRuntime({ gamePath: `  ${game}  `, steam: noSteam }), found);
});

test('a wrong setting is reported and the search goes on', (t) => {
  const base = scratch(t);
  const itself = makeRuntime(path.join(base, 'itself'));
  const nowhere = path.join(base, 'nowhere');
  const found = paths.findRuntime({ runtimePath: nowhere, folders: [itself], steam: noSteam });
  assert.equal(found.dir, itself);
  assert.equal(found.problem, `The setting wax.runtimePath is "${nowhere}". That is not the ICARUS folder or the Wax folder.`);
  assert.match(paths.findRuntime({ gamePath: nowhere, steam: noSteam }).problem, /^The setting wax\.gamePath is /);
  // the first setting that is wrong is the one named
  assert.match(paths.findRuntime({ runtimePath: nowhere, gamePath: nowhere, steam: noSteam }).problem, /wax\.runtimePath/);
  // one wrong setting does not stop the other from being used
  assert.deepEqual(paths.findRuntime({ runtimePath: nowhere, gamePath: itself, steam: noSteam }),
    { dir: itself, source: 'setting', game: null, problem: found.problem });
});

test('a game without Wax is told apart from no game at all', (t) => {
  const base = scratch(t);
  const game = makeGame(path.join(base, 'Icarus'));
  const other = makeGame(path.join(base, 'other'));
  const bare = { dir: null, source: null, game, problem: null };
  assert.deepEqual(paths.findRuntime({ gamePath: game, steam: noSteam }), bare);
  assert.deepEqual(paths.findRuntime({ steam: () => [{ game, runtime: null }] }), bare);
  assert.deepEqual(paths.findRuntime({ gamePath: game, steam: () => [{ game: other, runtime: null }] }), bare, 'the game the setting names');
  // a copy of the game that has Wax is taken before one that does not
  const withWax = makeRuntime(waxIn(other));
  assert.deepEqual(paths.findRuntime({ steam: () => [{ game, runtime: null }, { game: other, runtime: withWax }] }),
    { dir: withWax, source: 'steam', game: other, problem: null });
});

test('what is said when Wax is not found names what is missing', (t) => {
  const game = path.join(scratch(t), 'Icarus');
  const noWax = paths.missing({ dir: null, source: null, game, problem: null });
  assert.equal(noWax.text, `Wax is not installed in the game at ${game}. Download it, then run "Install Wax.cmd".`);
  assert.equal(noWax.gameFound, true);
  const noGame = paths.missing(nothing);
  assert.equal(noGame.text, 'Wax: the ICARUS folder was not found. Choose the folder the game is installed in.');
  assert.equal(noGame.gameFound, false);
  const wrong = paths.missing({ ...nothing, problem: 'The setting wax.gamePath is "X:\\no". That is not the ICARUS folder or the Wax folder.' });
  assert.match(wrong.text, /^The setting wax\.gamePath is "X:\\no"\. .* Choose the folder ICARUS is installed in\.$/);
  // a missing game and a missing Wax are two things to say, however the settings read
  assert.notEqual(noWax.situation, noGame.situation);
  assert.equal(wrong.situation, noGame.situation, 'a setting typed letter by letter is not news each time');
  assert.equal(paths.missing({ ...nothing, game: game.toUpperCase() }).situation, noWax.situation);
  assert.notEqual(paths.missing({ ...nothing, game: `${game}2` }).situation, noWax.situation, 'another copy of the game');
});

test('a folder with Scripts but no mods is not taken for the Wax folder', (t) => {
  const base = scratch(t);
  put(base, { 'game/Scripts/main.lua': 'print("some other project")\n' });
  assert.equal(paths.findRuntime({ folders: [path.join(base, 'game')], steam: noSteam }).dir, null);
});

test('the mods folder of the Wax folder, or one mod in it, opened alone still finds it', (t) => {
  const runtime = makeRuntime(path.join(scratch(t), 'Wax'));
  put(runtime, { 'mods/Hello/init.lua': 'return {}\n' });
  assert.equal(paths.findRuntime({ folders: [path.join(runtime, 'mods')], steam: noSteam }).dir, runtime);
  assert.equal(paths.findRuntime({ folders: [path.join(runtime, 'mods', 'Hello')], steam: noSteam }).dir, runtime);
});

test('mods live in luamods when the workspace has it, otherwise in the Wax folder', (t) => {
  const base = scratch(t);
  const runtime = makeRuntime(path.join(base, 'Wax'));
  const workspace = path.join(base, 'workspace');
  fs.mkdirSync(path.join(workspace, 'luamods'), { recursive: true });
  assert.equal(paths.findModsDir({ folders: [base, workspace], runtime }), path.join(workspace, 'luamods'));
  assert.equal(paths.findModsDir({ folders: [base], runtime }), path.join(runtime, 'mods'));
  assert.equal(paths.findModsDir({ folders: [base], runtime: null }), null);
  assert.equal(paths.findModsDir({ folders: [workspace], runtime: null }), path.join(workspace, 'luamods'));
});

test('this workspace is found as it is laid out', () => {
  const found = paths.findRuntime({ folders: [ROOT], steam: noSteam });
  assert.equal(found.dir, path.join(ROOT, 'wax', 'runtime'));
  assert.equal(paths.findModsDir({ folders: [ROOT], runtime: found.dir }), path.join(ROOT, 'luamods'));
});

test('isInside knows a folder from its neighbours', () => {
  assert.ok(paths.isInside('C:\\a\\b', 'C:\\a\\b'));
  assert.ok(paths.isInside('C:\\a\\b', 'c:\\A\\B\\c\\d.lua'));
  assert.ok(!paths.isInside('C:\\a\\b', 'C:\\a\\bc'));
  assert.ok(!paths.isInside('C:\\a\\b', 'C:\\a'));
  assert.ok(!paths.isInside('C:\\a\\b', 'D:\\a\\b\\c'));
});

test('mods on disk: folders with an init.lua or a mod.lua, with what their manifest says', (t) => {
  const modsDir = scratch(t);
  put(modsDir, {
    'Beta/init.lua': 'return {}\n',
    'Beta/sub/util.lua': 'return {}\n',
    'Beta/.luarc.json': '{}\n',
    'Beta/notes.txt': 'x',
    'Alpha/mod.lua': 'return {\n    name = "Alpha Mod", -- shown in the menu\n    description = "Does a thing.",\n    version = \'1.2.3\',\n    main = "main.lua",\n    dependencies = { "Beta" },\n}\n',
    'Alpha/main.lua': 'return {}\n',
    'OnlyManifest/mod.lua': 'return {}\n',
    'NotAMod/readme.md': 'x',
    'has space/init.lua': 'return {}\n',
    '__internal/init.lua': 'return {}\n',
    'loose.lua': 'return {}\n',
  });
  const mods = scanMods(modsDir);
  assert.deepEqual(mods.map((mod) => mod.id), ['Alpha', 'Beta', 'OnlyManifest']);
  const [alpha, beta] = mods;
  assert.deepEqual({ name: alpha.name, description: alpha.description, version: alpha.version, main: alpha.main, dependencies: alpha.dependencies },
    { name: 'Alpha Mod', description: 'Does a thing.', version: '1.2.3', main: 'main.lua', dependencies: ['Beta'] });
  assert.deepEqual(beta.files, ['init.lua', 'sub/util.lua']);
  assert.deepEqual({ name: beta.name, description: beta.description, version: beta.version, main: beta.main, dependencies: beta.dependencies },
    { name: 'Beta', description: null, version: null, main: 'init.lua', dependencies: [] });
  assert.deepEqual(listLuaFiles(path.join(modsDir, 'missing')), []);
  assert.deepEqual(scanMods(path.join(modsDir, 'missing')), []);
  assert.deepEqual(scanMods(null), []);

  assert.deepEqual(modOf(path.join(modsDir, 'Beta', 'sub', 'util.lua'), mods), { mod: beta, relative: 'sub/util.lua' });
  assert.equal(modOf(path.join(modsDir, 'loose.lua'), mods), null);
  assert.equal(modOf(path.join(modsDir, 'Beta'), mods), null);
  assert.equal(modOf(path.join(modsDir, 'BetaTwo', 'init.lua'), mods), null);
});

test('a manifest is read without running it, and comments in it are not', () => {
  const manifest = readManifest('-- name = "Commented"\nreturn {\n    name = "Real \\"one\\"",\n    --[[ version = "9" ]]\n    dependencies = { "A", \'B-2\' }, -- dependencies = { "C" }\n}\n');
  assert.deepEqual(manifest, { name: 'Real "one"', description: null, version: null, main: null, dependencies: ['A', 'B-2'] });
});
