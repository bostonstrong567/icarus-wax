'use strict';
// The docs site and the download page, and which docs page matches a name used in a mod
const { mask } = require('./luatext');

const DOCS = 'https://wax-icarus.duckdns.org/';
const DOWNLOAD = 'https://wax-icarus.duckdns.org/docs/install/';

// Pages of the docs site by their path under docs/, with the title each one has there.
const PAGES = {
  'install': 'Installing',
  'first-mod': 'Your first mod',
  'mods': 'How a mod is built',
  'menu': 'The menu',
  'debug-panel': 'The Wax panel',
  'game': 'The game tree',
  'tasks': 'Tasks',
  'signals': 'Signals',
  'storage': 'Saving settings',
  'logging': 'Printing and the log',
  'gui/windows': 'Windows',
  'gui/controls': 'Controls',
  'gui/grid': 'Grid',
  'gui/notifications': 'Notifications',
  'gui/overlays': 'Overlays',
  'gui/hotkeys': 'Hotkeys',
  'gui/themes': 'Themes',
  'gui/icons': 'Icons',
  'reference/ui': 'ui',
};

// Headings inside a page, as "page#anchor", with the heading's text.
const SECTIONS = {
  'mods#modlua': 'mod.lua',
  'mods#the-mod-table': 'The mod table',
  'mods#more-than-one-file': 'More than one file',
  'mods#using-another-mod': 'Using another mod',
  'mods#functions-that-are-blocked': 'Functions that are blocked',
};

const CONTROLS = ['Label', 'Heading', 'Title', 'Separator', 'Spacer', 'Button', 'Icon', 'Toggle', 'Slider', 'Input', 'Dropdown',
  'Keybind', 'Progress', 'Field', 'Section', 'Row', 'Flow', 'Console'];
for (const control of CONTROLS) SECTIONS[`gui/controls#${control.toLowerCase()}`] = control;

// What a control is added with (window:Button) -> where it is explained.
const METHODS = { Grid: 'gui/grid' };
for (const control of CONTROLS) METHODS[control] = `gui/controls#${control.toLowerCase()}`;

const spread = (place, names) => Object.fromEntries(names.map((name) => [name, place]));

// A name as written in a mod -> where it is explained. A name not listed takes the page of the global it starts with.
const NAMES = {
  ui: 'reference/ui',
  game: 'game',
  task: 'tasks',
  Signal: 'signals',
  storage: 'storage',
  persist: 'storage',
  print: 'logging',
  log: 'logging',
  require: 'mods#more-than-one-file',
  mod: 'mods#the-mod-table',
  raw: 'mods#functions-that-are-blocked',
  ...spread('gui/windows', ['ui.Window', 'ui.Windows']),
  ...spread('gui/overlays', ['ui.Overlay']),
  ...spread('gui/notifications', ['ui.Notify', 'ui.Notifications']),
  ...spread('gui/hotkeys', ['ui.Hotkey']),
  ...spread('gui/icons', ['ui.Icons']),
  ...spread('debug-panel', ['ui.Debug']),
  ...spread('gui/themes', ['ui.SetTheme', 'ui.ResetTheme', 'ui.Themes', 'ui.AddTheme', 'ui.ThemeName', 'ui.Theme', 'ui.ThemeChanged',
    'ui.Color', 'ui.SetScale', 'ui.GetScale', 'ui.MinScale', 'ui.AddSettings']),
  ...spread('menu', ['ui.Open', 'ui.Close', 'ui.Toggle', 'ui.IsOpen', 'ui.Opened', 'ui.Closed', 'ui.SetPreview', 'ui.IsPreview',
    'ui.SetToggleKey', 'ui.GetToggleKey', 'ui.KeyChanged']),
};

// Where each problem with a require is explained.
const PROBLEMS = {
  'undeclared': 'mods#using-another-mod',
  'not-installed': 'mods#using-another-mod',
  'missing-module': 'mods#more-than-one-file',
};

// The address of the site: the one given when it is a web address, otherwise the docs site.
function site(base) {
  const text = String(base ?? '').trim();
  return /^https?:\/\/\S+$/i.test(text) ? text.replace(/\/*$/, '/') : DOCS;
}

// The address of a page ("gui/windows") or of a heading in one ("mods#using-another-mod").
function address(place, base) {
  const [page, anchor] = place.split('#');
  return `${site(base)}docs/${page}/${anchor ? `#${anchor}` : ''}`;
}

const titleOf = (place) => SECTIONS[place] ?? PAGES[place.split('#')[0]] ?? null;

// A link to a page or heading: { title, url }.
const link = (place, base) => ({ title: titleOf(place), url: address(place, base) });

// The docs for the name at `column` of a line of Lua: { name, title, url }, or null when Wax has no page for it.
function topicAt(line, column, base) {
  const clean = mask(String(line), { strings: true });
  let start = Math.min(Math.max(column, 0), clean.length);
  let end = start;
  while (start > 0 && /\w/.test(clean[start - 1])) start--;
  while (end < clean.length && /\w/.test(clean[end])) end++;
  if (start === end) return null;
  const word = clean.slice(start, end);
  const owner = /(?:^|[^\w.:])([A-Za-z_]\w*)\s*([.:])\s*$/.exec(clean.slice(0, start));
  const before = clean.slice(0, start).trimEnd().slice(-1);
  let name = null;
  let place = null;
  if (before === ':') {
    name = word;
    place = Object.hasOwn(METHODS, word) ? METHODS[word] : null;
  } else if (before === '.') {
    if (!owner || !Object.hasOwn(NAMES, owner[1])) return null;
    name = `${owner[1]}.${word}`;
    place = Object.hasOwn(NAMES, name) ? NAMES[name] : NAMES[owner[1]];
  } else {
    name = word;
    place = Object.hasOwn(NAMES, word) ? NAMES[word] : null;
  }
  return place ? { name, ...link(place, base) } : null;
}

module.exports = { DOCS, DOWNLOAD, PAGES, SECTIONS, METHODS, NAMES, PROBLEMS, site, address, titleOf, link, topicAt };
