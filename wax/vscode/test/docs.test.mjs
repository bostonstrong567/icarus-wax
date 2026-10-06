// Links into the docs site: their addresses, and that each one points at a page and heading the docs have
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { require, read, ROOT } from './helpers.mjs';

const docs = require('../lib/docs.js');

const CONTENT = path.join(ROOT, 'docs', 'content', 'docs');
const SITE = 'https://wax-icarus.duckdns.org/';
const places = [...new Set([...Object.keys(docs.PAGES), ...Object.keys(docs.SECTIONS), ...Object.values(docs.METHODS),
  ...Object.values(docs.NAMES), ...Object.values(docs.PROBLEMS)])];

test('the two addresses are the docs site and the download page', () => {
  assert.equal(docs.DOCS, SITE);
  assert.equal(docs.DOWNLOAD, 'https://wax-icarus.duckdns.org/docs/install/');
});

test('a page and a heading in a page each have an address under the docs site', () => {
  assert.equal(docs.address('mods'), `${SITE}docs/mods/`);
  assert.equal(docs.address('gui/windows'), `${SITE}docs/gui/windows/`);
  assert.equal(docs.address('mods#using-another-mod'), `${SITE}docs/mods/#using-another-mod`);
  assert.deepEqual(docs.link('gui/controls#button'), { title: 'Button', url: `${SITE}docs/gui/controls/#button` });
  assert.deepEqual(docs.link('storage'), { title: 'Saving settings', url: `${SITE}docs/storage/` });
  for (const place of places) {
    assert.ok(docs.address(place).startsWith(`${SITE}docs/`), place);
    assert.ok(docs.titleOf(place), `${place} has a title`);
  }
});

test('the docs address from the settings is used when it is a web address, with or without its last slash', () => {
  assert.equal(docs.site('http://localhost:3000'), 'http://localhost:3000/');
  assert.equal(docs.site('  https://example.test/wax/  '), 'https://example.test/wax/');
  assert.equal(docs.address('tasks', 'http://localhost:3000'), 'http://localhost:3000/docs/tasks/');
  for (const other of ['', '   ', undefined, null, 'docs', 'file:///C:/docs/', 'javascript:alert(1)', 'https://two words/']) {
    assert.equal(docs.site(other), SITE, String(other));
  }
});

// The topic for the first place `find` shows up in `line`, one character into it.
const topic = (line, find) => docs.topicAt(line, line.indexOf(find) + 1);
const page = (line, find) => (topic(line, find) ?? {}).url?.slice(SITE.length);

test('a Wax name in code leads to the page that explains it', () => {
  assert.deepEqual(topic('local w = ui.Window({})', 'Window'), { name: 'ui.Window', title: 'Windows', url: `${SITE}docs/gui/windows/` });
  assert.equal(page('ui.Overlay({ anchor = "top" })', 'Overlay'), 'docs/gui/overlays/');
  assert.equal(page('ui.Notify("x")', 'Notify'), 'docs/gui/notifications/');
  assert.equal(page('ui.Hotkey("F6", f)', 'Hotkey'), 'docs/gui/hotkeys/');
  assert.equal(page('ui.SetTheme("Dune")', 'SetTheme'), 'docs/gui/themes/');
  assert.equal(page('if ui.IsOpen() then', 'IsOpen'), 'docs/menu/');
  assert.equal(page('ui.Copy(text)', 'Copy'), 'docs/reference/ui/', 'a member with no page of its own takes the page of ui');
  assert.equal(page('ui.Copy(text)', 'ui'), 'docs/reference/ui/');
  assert.equal(page('local c = game.Character', 'Character'), 'docs/game/');
  assert.equal(page('local c = game.Character', 'game'), 'docs/game/');
  assert.equal(page('task.spawn(function() end)', 'spawn'), 'docs/tasks/');
  assert.equal(page('local s = Signal.new("x")', 'Signal'), 'docs/signals/');
  assert.equal(page('storage.Save("settings", t)', 'Save'), 'docs/storage/');
  assert.equal(page('local state = persist("state", {})', 'persist'), 'docs/storage/');
  assert.equal(page('print("hi")', 'print'), 'docs/logging/');
  assert.equal(page('log:warn("careful")', 'log'), 'docs/logging/');
  assert.equal(page('local util = require("util")', 'require'), 'docs/mods/#more-than-one-file');
  assert.equal(page('print(mod.id)', 'mod'), 'docs/mods/#the-mod-table');
  assert.equal(page('raw.LoopAsync(1, f)', 'raw'), 'docs/mods/#functions-that-are-blocked');
  assert.equal(page('  ui . Window ( {} )', 'Window'), 'docs/gui/windows/', 'spaces around the dot');
});

test('a control added with a colon leads to its part of the Controls page', () => {
  assert.deepEqual(topic('window:Button("Go", go)', 'Button'), { name: 'Button', title: 'Button', url: `${SITE}docs/gui/controls/#button` });
  assert.equal(page('section:Toggle("On", true)', 'Toggle'), 'docs/gui/controls/#toggle');
  assert.equal(page('ui.Toggle()', 'Toggle'), 'docs/menu/', 'ui.Toggle is the menu, not the switch');
  assert.equal(page('page:Grid({ make = make, show = show })', 'Grid'), 'docs/gui/grid/');
  assert.equal(page('field:Set(1)', 'Set'), undefined);
  assert.equal(page('game.MapChanged:Connect(f)', 'Connect'), undefined);
});

test('names that are not Wax\'s, and text in strings and comments, lead nowhere', () => {
  assert.equal(topic('local window = 1', 'window'), null);
  assert.equal(topic('self.game.Speed = 2', 'game'), null, 'a field of something else');
  assert.equal(topic('self.game.Speed = 2', 'Speed'), null);
  assert.equal(topic('other.ui.Window()', 'Window'), null);
  assert.equal(topic('my.print("x")', 'print'), null);
  assert.equal(topic('print("ui.Window")', 'Window'), null, 'inside a string');
  assert.equal(topic('local x = 1 -- ui.Window', 'Window'), null, 'inside a comment');
  assert.equal(topic('a.toString()', 'toString'), null, 'a name every JavaScript object has');
  assert.equal(topic('x:constructor()', 'constructor'), null);
  assert.equal(docs.topicAt('', 0), null);
  assert.equal(docs.topicAt('ui.Window()', 99), null, 'past the end of the line');
});

test('a hover on the last character of a name, or right after it, still finds the name', () => {
  const line = 'task.wait(1)';
  assert.equal(docs.topicAt(line, 0).name, 'task');
  assert.equal(docs.topicAt(line, 4).name, 'task');
  assert.equal(docs.topicAt(line, 5).name, 'task.wait');
  assert.equal(docs.topicAt(line, 9).name, 'task.wait');
  assert.equal(docs.topicAt(line, 10), null);
});

test('every name with a page of its own is one Wax has', () => {
  const types = (name) => read(path.join(ROOT, 'wax', 'types', name));
  const ui = types('ui.lua');
  for (const name of Object.keys(docs.NAMES).filter((entry) => entry.startsWith('ui.'))) {
    const member = name.slice(3);
    assert.ok(ui.includes(`function ui.${member}(`) || new RegExp(`^---@field ${member} `, 'm').test(ui), name);
  }
  const globals = ['ui.lua', 'game.lua', 'task.lua', 'mod.lua'].map(types).join('\n');
  for (const name of Object.keys(docs.NAMES).filter((entry) => !entry.includes('.'))) {
    assert.ok(new RegExp(`^(${name} = |function ${name}\\()`, 'm').test(globals), name);
  }
  const controls = types('controls.lua');
  for (const method of Object.keys(docs.METHODS)) assert.ok(controls.includes(`function Container:${method}(`), method);
});

// A heading's anchor, made the way the docs site makes it.
const anchorOf = (heading) => heading.trim().toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/\s/g, '-');

test('every place the extension links to is in the docs, under the title the link shows',
  { skip: !fs.existsSync(CONTENT) && 'the docs are not in this workspace' }, () => {
    for (const place of places) {
      const [name, anchor] = place.split('#');
      const file = path.join(CONTENT, `${name}.mdx`);
      assert.ok(fs.existsSync(file), `${place}: docs\\content\\docs\\${name}.mdx`);
      const text = read(file);
      const title = (/^title:\s*(.*)$/m.exec(text) ?? [])[1].trim().replace(/^"(.*)"$/, '$1');
      assert.equal(docs.PAGES[name], title, `the title of ${name}`);
      if (!anchor) continue;
      const headings = [...text.matchAll(/^#{2,4}\s+(.+)$/gm)].map((match) => match[1].trim());
      const heading = headings.find((entry) => anchorOf(entry) === anchor);
      assert.ok(heading, `${place}: no heading in ${name}.mdx gives #${anchor}`);
      assert.equal(docs.SECTIONS[place], heading, place);
    }
  });
