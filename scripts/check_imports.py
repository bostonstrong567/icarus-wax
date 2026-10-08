#!/usr/bin/env python3
"""What a cooked package imports, checked against the game before the game loads it.

The game stops with a fatal error when a package imports an object that is missing from a package the game
has (AsyncLoading.cpp, FAsyncPackage::LinkImport), and when the parent of a class or function is missing
altogether ("Could not find SuperStruct"). This reads the import table of each cooked file and looks every
import up: the game's assets in the asset registry and in the game's own packages (read out of the paks with
repak, nothing is unpacked), native types in the list of the game's native types.

  python scripts\\check_imports.py <cooked .uasset or a folder of them> [...] [--content <Content folder>]
                                  [--own /Game/Mods/X/Y] [--no-natives] [--strict-natives] [--verbose]
  python scripts\\check_imports.py natives
  python scripts\\check_imports.py imports <file.uasset> [--names]
  python scripts\\check_imports.py cooked <file or folder> [...]
  python scripts\\check_imports.py plan /Game/Path/Asset [...] --json plan.json [--limit N] [--no-imports] [--no-materials]
  python scripts\\check_imports.py fetch plan.json <Content folder>

plan and fetch are what Get-GameAsset.ps1 runs: the same reader says which game packages a package needs.
The asset registry is read out of the game's first pak by the model's parser (scripts\\gamemodel\\registry.py).
Native types come from the model of the installed build (build\\game-model\\<build>\\native.json, made from the
exe, so it names every native module and type): a native import it lacks fails the check. Without that file
they are looked up in build\\game-index\\index.json, which is not this build's model, so a miss there is only
named and fails the check with --strict-natives. A part of a native default object is in no list and is only
ever named. With no list at all the check does not run, unless --no-natives leaves native imports out.
Exit code: 0 good, 1 something is wrong with the content, 2 the check could not run.
"""
import argparse
import difflib
import glob
import importlib
import json
import os
import re
import struct
import subprocess
import sys
import time
import traceback

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPAK = os.path.join(ROOT, 'tools', 'pak', 'repak', 'repak.exe')
CACHE = os.path.join(ROOT, 'build', 'cook')
INDEX = os.path.join(ROOT, 'build', 'game-index', 'index.json')
MODEL_NATIVE = 'native.json'
APP_ID = '1149460'
FIRST_PAK = 'pakchunk0-WindowsNoEditor.pak'
REGISTRY_IN_PAK = 'Icarus/AssetRegistry.bin'
PACKAGE_TAG = 0x9E2A83C1
PKG_FILTER_EDITOR_ONLY = 0x80000000
HEADS = ('.uasset', '.umap')
PARTS = HEADS + ('.uexp', '.ubulk', '.uptnl', '.ufont')
CLASS_ASSETS = {'blueprint': 'BlueprintGeneratedClass', 'widget': 'WidgetBlueprintGeneratedClass',
                'anim': 'AnimBlueprintGeneratedClass', 'rig': 'ControlRigBlueprintGeneratedClass',
                'struct': 'UserDefinedStruct', 'enum': 'UserDefinedEnum'}
LISTED_NOT_COOKED = ('ObjectRedirector',)
FATAL, MISSING, UNSEEN = 'FATAL', 'MISSING', 'UNSEEN'
READ_ERRORS = (OSError, ValueError, KeyError, TypeError, AttributeError, IndexError, struct.error)
NO_NATIVES = ('There is no list of the game\'s native types, so native imports cannot be checked. '
              'Make it: python scripts\\gamemodel\\native.py (it reads the game\'s exe; the game need not run).')


class Problem(Exception):
    """Something the person has to put right before the check can run."""


class Unopened(Problem):
    """A file that could not be opened at all, which says nothing about what is in it."""


def said(error):
    return '%s: %s' % (type(error).__name__, error)


class Package:
    """Names, imports and exports of a UE 4.27 package file. Export data (.uexp) is never read."""

    def __init__(self, data, tables=True):
        self.d = data
        self.p = 0
        self.names = []
        self.imports = []
        self.exports = []
        self._table = None
        try:
            self._read(tables)
        except (struct.error, IndexError, UnicodeDecodeError):
            raise Problem('This is not a package the reader knows (it ends early or its tables do not fit).')

    def _i32(self):
        value = struct.unpack_from('<i', self.d, self.p)[0]
        self.p += 4
        return value

    def _u32(self):
        value = struct.unpack_from('<I', self.d, self.p)[0]
        self.p += 4
        return value

    def _i64(self):
        value = struct.unpack_from('<q', self.d, self.p)[0]
        self.p += 8
        return value

    def _fstring(self):
        count = self._i32()
        if count == 0:
            return ''
        if count < 0:
            text = self.d[self.p:self.p - count * 2].decode('utf-16-le')
            self.p += -count * 2
        else:
            text = self.d[self.p:self.p + count].decode('latin-1')
            self.p += count
        return text.rstrip('\x00')

    def _name(self):
        index = self._i32()
        number = self._i32()
        text = self.names[index]
        return '%s_%d' % (text, number - 1) if number else text

    def _read(self, tables):
        if len(self.d) < 4 or self._u32() != PACKAGE_TAG:
            raise Problem('This is not a package file (it does not start with the package tag).')
        legacy = self._i32()
        if legacy != -4:
            self._i32()
        self.file_version = self._i32()
        self._i32()
        if legacy <= -2:
            versions = self._i32()
            self.p += versions * 20
        self._i32()
        self._fstring()
        self.flags = self._u32()
        self.cooked = bool(self.flags & PKG_FILTER_EDITOR_ONLY)
        self.unversioned = self.file_version == 0
        if not tables:
            return
        name_count = self._i32()
        name_offset = self._i32()
        if not self.cooked:
            self._fstring()
        self._i32()
        self._i32()
        export_count = self._i32()
        export_offset = self._i32()
        import_count = self._i32()
        import_offset = self._i32()

        self.p = name_offset
        for _ in range(name_count):
            self.names.append(self._fstring())
            self.p += 4

        self.p = import_offset
        for _ in range(import_count):
            class_package = self._name()
            class_name = self._name()
            outer = self._i32()
            name = self._name()
            if not self.cooked:
                self._name()
            self.imports.append({'class_package': class_package, 'class_name': class_name, 'outer': outer, 'name': name})

        self.p = export_offset
        for _ in range(export_count):
            class_index = self._i32()
            super_index = self._i32()
            self._i32()
            outer = self._i32()
            name = self._name()
            self.p += 4 + 8 + 8 + 12 + 16 + 4 + 4 + 4 + 20
            self.exports.append({'class': class_index, 'super': super_index, 'outer': outer, 'name': name})

    def import_path(self, index):
        """Import number index (from 0) as its chain of names, the package first."""
        chain = []
        at = -index - 1
        while at < 0:
            item = self.imports[-at - 1]
            chain.append(item['name'])
            at = item['outer']
        if at > 0:
            chain.extend(reversed(self.export_path(at - 1)))
        return list(reversed(chain))

    def export_path(self, index):
        """Export number index (from 0) as its chain of names inside this package, the outermost first."""
        chain = []
        at = index + 1
        while at > 0:
            item = self.exports[at - 1]
            chain.append(item['name'])
            at = item['outer']
        return list(reversed(chain))

    def export_class(self, index):
        at = self.exports[index]['class']
        if at < 0:
            return self.imports[-at - 1]['name']
        if at > 0:
            return self.exports[at - 1]['name']
        return 'Class'

    def export_table(self):
        """({lower-case path: [class, ...]}, {lower-case path of the outer: [name, ...]}) of every export."""
        if self._table is None:
            classes, inside = {}, {}
            for index in range(len(self.exports)):
                names = self.export_path(index)
                key = tuple(name.lower() for name in names)
                classes.setdefault(key, []).append(self.export_class(index))
                inside.setdefault(key[:-1], []).append(names[-1])
            self._table = classes, inside
        return self._table


def load_package(path, tables=True):
    try:
        with open(path, 'rb') as handle:
            data = handle.read() if tables else handle.read(65536)
    except OSError as error:
        raise Unopened('%s cannot be read: %s' % (path, error.strerror or error))
    try:
        return Package(data, tables)
    except Problem as error:
        raise Problem('%s: %s' % (path, error))


def lower_priority():
    """Readers run below normal priority, and so does every repak they start: the game may be running."""
    try:
        import ctypes
        kernel = ctypes.WinDLL('kernel32')
        kernel.GetCurrentProcess.restype = ctypes.c_void_p
        kernel.SetPriorityClass.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        kernel.SetPriorityClass(kernel.GetCurrentProcess(), 0x4000)
    except (ImportError, AttributeError, OSError):
        pass


def find_paks():
    """The game's Paks folder: "gameDir" in icarus.config.json, else where Steam has the game."""
    folders = []
    try:
        with open(os.path.join(ROOT, 'icarus.config.json'), encoding='utf-8-sig') as handle:
            folders.append(json.load(handle).get('gameDir'))
    except (OSError, ValueError, AttributeError):
        pass
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r'Software\Valve\Steam') as key:
            steam = winreg.QueryValueEx(key, 'SteamPath')[0]
        libraries = [steam]
        try:
            with open(os.path.join(steam, 'steamapps', 'libraryfolders.vdf'), encoding='utf-8', errors='replace') as handle:
                libraries += [path.replace('\\\\', '\\') for path in re.findall(r'"path"\s+"([^"]+)"', handle.read())]
        except OSError:
            pass
        for library in libraries:
            try:
                with open(os.path.join(library, 'steamapps', 'appmanifest_%s.acf' % APP_ID), encoding='utf-8', errors='replace') as handle:
                    found = re.search(r'"installdir"\s+"([^"]*)"', handle.read())
            except OSError:
                continue
            if found:
                folders.append(os.path.join(library, 'steamapps', 'common', found.group(1)))
    except (ImportError, OSError):
        pass
    for folder in folders:
        paks = os.path.join(folder, 'Icarus', 'Content', 'Paks') if folder else None
        if paks and os.path.isfile(os.path.join(paks, FIRST_PAK)):
            return os.path.normpath(paks)
    raise Problem('The game was not found. Set "gameDir" in icarus.config.json, or pass --paks with the game\'s Paks folder.')


class Game:
    """The installed game's paks, read through repak. The game folder is only ever read."""

    def __init__(self, paks=None, repak=REPAK, cache=CACHE):
        self.paks = paks or find_paks()
        self.repak = repak
        self.cache = cache
        if not os.path.isfile(self.repak):
            raise Problem('repak was not found at %s. Run scripts\\Get-Tools.ps1.' % self.repak)
        if not os.path.isfile(os.path.join(self.paks, FIRST_PAK)):
            raise Problem('%s has no %s. Is this the game\'s Paks folder?' % (self.paks, FIRST_PAK))
        self._files = None
        self._plugins = None
        self._names = None
        self._headers = {}

    def stamp(self, only=None):
        paks = [os.path.join(self.paks, only)] if only else sorted(glob.glob(os.path.join(self.paks, '*.pak')))
        return [[os.path.basename(pak), os.path.getsize(pak), int(os.path.getmtime(pak))] for pak in paks]

    def cached(self, name, stamp, make):
        """A value kept in the cache folder for as long as the paks it came from stay the same."""
        path = os.path.join(self.cache, name)
        try:
            with open(path, encoding='utf-8') as handle:
                saved = json.load(handle)
            if saved.get('stamp') == stamp:
                return saved['value']
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            pass
        value = make()
        os.makedirs(self.cache, exist_ok=True)
        with open(path + '.new', 'w', encoding='utf-8') as handle:
            json.dump({'stamp': stamp, 'value': value}, handle)
        os.replace(path + '.new', path)
        return value

    def _list(self):
        files = {}
        for pak in sorted(glob.glob(os.path.join(self.paks, '*.pak'))):
            done = subprocess.run([self.repak, 'list', pak], capture_output=True, text=True, encoding='utf-8', errors='replace')
            if done.returncode != 0:
                raise Problem('repak could not list %s: %s' % (pak, done.stderr.strip()[:300]))
            for line in done.stdout.splitlines():
                line = line.strip()
                base, extension = os.path.splitext(line)
                if extension.lower() in PARTS:
                    files.setdefault(base.lower(), []).append([os.path.basename(pak), line])
        return files

    @property
    def files(self):
        """Lower-case path without extension -> [[pak, path in the pak], ...] for every part of a package."""
        if self._files is None:
            self._files = self.cached('pak_files.json', self.stamp(), self._list)
        return self._files

    def _base(self, package):
        lower = package.lower()
        if lower.startswith('/game/'):
            return 'icarus/content/' + lower[6:]
        if lower.startswith('/engine/'):
            return 'engine/content/' + lower[8:]
        if lower.startswith('/script/'):
            return None
        if self._plugins is None:
            self._plugins = {}
            for base in self.files:
                at = base.find('/content/')
                if at > 0 and '/plugins/' in base[:at + 1]:
                    self._plugins[base[:at].rsplit('/', 1)[1] + '/' + base[at + 9:]] = base
        return self._plugins.get(lower.strip('/'))

    def parts(self, package):
        """Every file of a package as [pak, path in the pak]; empty when the game has no such package."""
        base = self._base(package)
        return self.files.get(base, []) if base else []

    def has(self, package):
        return any(path.lower().endswith(HEADS) for _, path in self.parts(package))

    def spelling(self, package):
        """A /Game package's name as the game's own files spell it; the name given when the game has none."""
        for _, path in self.parts(package):
            if path.lower().endswith(HEADS) and path.lower().startswith('icarus/content/'):
                return '/Game/' + os.path.splitext(path)[0][len('Icarus/Content/'):]
        return package

    def read(self, pak, path):
        done = subprocess.run([self.repak, 'get', os.path.join(self.paks, pak), path], capture_output=True)
        if done.returncode != 0 or not done.stdout:
            raise Problem('repak could not read %s out of %s: %s' % (path, pak, done.stderr.decode('utf-8', 'replace').strip()[:300]))
        return done.stdout

    def header(self, package):
        """The tables of a game package, or None when the game has no such package."""
        key = package.lower()
        if key not in self._headers:
            head = [part for part in self.parts(package) if part[1].lower().endswith(HEADS)]
            self._headers[key] = Package(self.read(*head[0])) if head else None
        return self._headers[key]

    def under(self, folder):
        """The /Game packages below a folder, in the game's own spelling."""
        base = self._base(folder.rstrip('/') + '/x')
        if not base or not base.startswith('icarus/content/'):
            return []
        prefix = base[:-1]
        found = []
        for key, parts in self.files.items():
            if key.startswith(prefix):
                for _, path in parts:
                    if path.lower().endswith(HEADS):
                        found.append('/Game/' + os.path.splitext(path)[0][len('Icarus/Content/'):])
        return sorted(found)

    def nearest(self, package, count=3):
        """Game packages a mistyped name most likely meant."""
        wanted = package.rstrip('/').rsplit('/', 1)[-1].lower()
        if self._names is None:
            self._names = {}
            for key, parts in self.files.items():
                if key.startswith('icarus/content/'):
                    self._names.setdefault(key.rsplit('/', 1)[-1], []).append(parts[0][1])
        names = self._names
        close = [wanted] if wanted in names else []
        close += [name for name in difflib.get_close_matches(wanted, list(names), n=count, cutoff=0.75) if name not in close]
        found = []
        for name in close:
            for path in names[name]:
                found.append('/Game/' + os.path.splitext(path)[0][len('Icarus/Content/'):])
        return found[:count]


def gamemodel_module(name=None):
    """scripts\\gamemodel, or one of its modules, imported with this folder on the path."""
    scripts = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, scripts)
    try:
        return importlib.import_module('gamemodel.' + name if name else 'gamemodel')
    finally:
        if scripts in sys.path:
            sys.path.remove(scripts)


def registry_tables(data):
    """An asset registry's bytes as ({object path: asset class}, {class path: parent path}), keys in lower case.

    Read by scripts\\gamemodel\\registry.py, the one parser of the registry."""
    try:
        parser = gamemodel_module('registry')
    except ImportError as error:
        raise Problem('scripts\\gamemodel holds the reader of the asset registry and could not be loaded (%s).' % error)
    try:
        registry = parser.Registry(data)
    except parser.RegistryError as error:
        raise Problem('The asset registry could not be read: %s' % error)
    assets, parents = {}, {}
    for asset in registry.assets:
        path, asset_class = asset[0].lower(), asset[3]
        assets[path] = asset_class
        if asset_class.endswith('GeneratedClass'):
            parent = parser.object_path(registry.tags(asset).get('ParentClass'))
            if parent:
                parents[path] = parent
    return assets, parents


class Registry:
    """Which assets the game has, and each blueprint class's parent."""

    def __init__(self, assets, parents, source):
        self.assets = assets
        self.parents = parents
        self.source = source

    @classmethod
    def load(cls, game, file=None):
        if file:
            try:
                if file.lower().endswith('.json'):
                    return cls.from_model(file)
                with open(file, 'rb') as handle:
                    return cls(*registry_tables(handle.read()), source=file)
            except Problem as error:
                raise Problem('%s is not a registry this reads. %s' % (file, error))
            except READ_ERRORS as error:
                raise Problem('%s is not a registry this reads (%s).' % (file, said(error)))
        value = game.cached('registry.json', game.stamp(FIRST_PAK),
                            lambda: list(registry_tables(game.read(FIRST_PAK, REGISTRY_IN_PAK))))
        return cls(value[0], value[1], source=os.path.join(game.paks, FIRST_PAK))

    @classmethod
    def from_model(cls, file):
        """A file of the game model: assets.json, or what gamemodel\\registry.py --json wrote.

        Only blueprint classes, structs and enums are taken. The model does not say what the asset of any
        other package is called, so those are looked up in the package itself."""
        with open(file, encoding='utf-8') as handle:
            model = json.load(handle)
        assets, parents = {}, {}
        classes = model['classes']
        records = [dict(record, path=path) for path, record in classes.items()] if isinstance(classes, dict) else classes
        for record in records:
            assets[record['path'].lower()] = CLASS_ASSETS[record['kind']]
            if record.get('parent'):
                parents[record['path'].lower()] = record['parent']
        for kind in ('structs', 'enums'):
            for record in model.get(kind, []):
                assets[record['path'].lower()] = CLASS_ASSETS[record['kind']]
        for path, record in model.get('types', {}).items():
            assets[path.lower()] = CLASS_ASSETS[record['kind']]
        return cls(assets, parents, source=file)

    def asset_class(self, package, name):
        """The class of a package's own asset, or None. A Blueprint and a redirector are listed and are not in a cooked package."""
        found = self.assets.get(('%s.%s' % (package, name)).lower())
        return None if found and (found.endswith('Blueprint') or found in LISTED_NOT_COOKED) else found

    def chain(self, class_path):
        """The parents of a blueprint class, nearest first, ending at its native class."""
        chain = []
        at = self.parents.get(class_path.lower())
        while at and len(chain) < 64:
            chain.append(at)
            if at.startswith('/Script/'):
                break
            at = self.parents.get(at.lower())
        return chain


def model_file(name):
    """A file of the model made for the installed build, when scripts\\gamemodel has made one; else None."""
    if not os.path.isdir(os.path.join(ROOT, 'build', 'game-model')):
        return None
    try:
        path = os.path.join(gamemodel_module().model_dir(), name)
        return path if os.path.isfile(path) else None
    except Exception:
        return None


class Natives:
    """The game's native modules, classes, structs, enums and functions.

    From the model's native.json when that is there, else from the class index. A list that names the game's
    modules itself (native.json does: it is made from the exe) is whole: what it lacks, the game lacks."""

    def __init__(self, index=None, use=True):
        self.names, self.modules, self.parents, self.by_name = set(), set(), {}, {}
        self.loaded = self.whole = False
        self.note = None
        self.file = index
        if not use:
            return
        model = None if index else model_file(MODEL_NATIVE)
        self.file = index or model or INDEX
        if not os.path.isfile(self.file):
            if index:
                raise Problem('%s is not there.' % index)
            return
        try:
            self._read(self.file)
        except READ_ERRORS as error:
            if not model:
                raise Problem(self._unread(self.file, error, named=bool(index)))
            self.note = '%s could not be read (%s); the class index is used instead' % (model, said(error))
            self.file = INDEX
            if not os.path.isfile(INDEX):
                raise Problem('%s could not be read (%s), and there is no class index to use instead. '
                              'Make it again: python scripts\\gamemodel\\native.py' % (model, said(error)))
            try:
                self._read(INDEX)
            except READ_ERRORS as second:
                raise Problem(self._unread(INDEX, second) + ' Before that, ' + self.note + '.')

    @staticmethod
    def _unread(file, error, named=False):
        text = '%s is not a list of native types this reads (%s).' % (file, said(error))
        return text if named else text + ' Make it again: python scripts\\gameindex.py build'

    def _read(self, file):
        """Reads a list into this object, or raises and leaves the object as it was."""
        with open(file, encoding='utf-8') as handle:
            data = json.load(handle)
        names, modules, parents, by_name = set(), set(), {}, {}
        listed = [package['name'].lower() for package in data.get('packages', []) if isinstance(package, dict) and package.get('name')]
        modules.update(listed)
        for cls in data['classes']:
            path = cls['path'].lower()
            names.add(path)
            names.add(('%s.Default__%s' % (cls['package'], cls['name'])).lower())
            modules.add(cls['package'].lower())
            by_name.setdefault(cls['name'].lower(), []).append(path)
            parent = cls.get('super') or cls.get('parent')
            if parent:
                parents[path] = parent.lower()
            for function in cls.get('functions', []):
                names.add(('%s.%s' % (path, function['name'] if isinstance(function, dict) else function)).lower())
        for kind in ('structs', 'enums', 'delegates'):
            for item in data.get(kind, []):
                path = item['path'].lower().replace(':', '.')
                names.add(path)
                modules.add(path.split('.', 1)[0])
        if not names:
            raise ValueError('it holds no classes')
        self.names, self.modules, self.parents, self.by_name = names, modules, parents, by_name
        self.whole = bool(listed)
        self.loaded = True

    def has(self, package, inner):
        return ('%s.%s' % (package, '.'.join(inner))).lower() in self.names

    def descends(self, class_name, ancestor_name):
        """True when the list shows the class to be the other one or a child of it."""
        ancestor = ancestor_name.lower()
        for path in self.by_name.get(class_name.lower(), []):
            for _ in range(64):
                if path.rsplit('.', 1)[-1] == ancestor:
                    return True
                path = self.parents.get(path)
                if not path:
                    break
        return False


def content_candidates(path):
    """The /Game names a file could have: one for each folder named Content above it, the outermost first."""
    stem = os.path.splitext(os.path.abspath(path).replace('\\', '/'))[0]
    return ['/Game/' + stem[found.start() + len('/Content/'):] for found in re.finditer('(?i)(?=/content/)', stem)]


def own_package(path, content=None, names=None):
    """The /Game name of a cooked file.

    Under the Content folder given it is the path below that folder. Without one it is the path below a folder
    named Content, and when there are several the one the file's own names hold says which."""
    if content:
        try:
            rel = os.path.relpath(os.path.abspath(path), os.path.abspath(content))
        except ValueError:
            rel = '..'
        if rel.startswith('..') or os.path.isabs(rel):
            raise Problem('%s is not under the Content folder given (%s), so its /Game name is not known.' % (path, content))
        return '/Game/' + os.path.splitext(rel)[0].replace('\\', '/')
    candidates = content_candidates(path)
    if len(candidates) > 1 and names:
        known = {name.lower() for name in names}
        for candidate in candidates:
            if candidate.lower() in known:
                return candidate
    return candidates[-1] if candidates else None


def check(path, game, registry, natives, own, package=None):
    """One cooked file: (the package, counts, what was found as (level, what, why)). own is in lower case."""
    package = package or load_package(path)
    if not package.cooked:
        raise Problem('%s is an editor asset, not a cooked file. Cook it first (scripts\\Cook-UnrealProject.ps1 -Content <Name>).' % path)
    counts = {'in the game': 0, 'native': 0, 'native not seen': 0, 'own': 0}
    found = {}
    for number, item in enumerate(package.imports):
        chain = package.import_path(number)
        root, inner = chain[0], chain[1:]
        what = '%s %s' % (item['class_name'], '.'.join(chain))
        wanted = item['class_name'].lower()
        if root.lower() in own:
            counts['own'] += 1 if inner else 0
        elif root.lower().startswith('/script/'):
            if not natives.loaded:
                counts['native not seen'] += 1 if inner else 0
            elif not inner:
                if root.lower() in natives.modules:
                    pass
                elif natives.whole:
                    found[number] = (MISSING, what, 'the game has no such native module (the model made from its exe has all of them); what comes from it is empty in the game')
                else:
                    found[number] = (UNSEEN, what, 'no native type of this module is in the class index; if the game lacks the module, what comes from it is empty there')
            elif natives.has(root, inner):
                counts['native'] += 1
            else:
                counts['native not seen'] += 1
                if len(inner) > 1 and inner[0].lower().startswith('default__'):
                    found[number] = (UNSEEN, what, 'a part of a native default object, which no list here holds; the game stops if it is missing')
                elif natives.whole:
                    found[number] = (MISSING, what, 'not among the game\'s native types (the model made from its exe), so this is empty in the game')
                else:
                    found[number] = (UNSEEN, what, 'not in the class index, which may lack types the game has; the game stops or leaves this empty if it really is missing')
        elif not game.has(root):
            near = game.nearest(root) if root.lower().startswith('/game/') else []
            found[number] = (MISSING, what, 'the game has no such package, so this is empty in the game'
                             + ('; nearest: ' + ', '.join(near) if near else ''))
        elif not inner:
            pass
        elif len(inner) == 1 and (registry.asset_class(root, inner[0]) or '').lower() == wanted:
            counts['in the game'] += 1
        else:
            classes, inside = game.header(root).export_table()
            key = tuple(name.lower() for name in inner)
            there = classes.get(key)
            if there and any(cls.lower() == wanted or natives.descends(cls, item['class_name']) for cls in there):
                counts['in the game'] += 1
            elif there and not natives.loaded:
                found[number] = (UNSEEN, what, 'the game has it as class %s; with no list of native types it cannot be told whether that is a kind of %s'
                                 % (there[-1], item['class_name']))
            elif there:
                found[number] = (FATAL, what, 'the game has it as class %s; the game stops when it loads this' % there[-1])
            else:
                near = difflib.get_close_matches(inner[-1], inside.get(key[:-1], []), n=1, cutoff=0.6)
                found[number] = (FATAL, what, 'the game\'s package has no object of that name%s; the game stops when it loads this'
                                 % (' (nearest: %s)' % near[0] if near else ''))

    def lacking(number):
        """True when the game lacks this import or something it lies in."""
        at = -number - 1
        while at < 0:
            if found.get(-at - 1, ('',))[0] == MISSING:
                return True
            at = package.imports[-at - 1]['outer']
        return False

    for index, export in enumerate(package.exports):
        number = -export['super'] - 1
        if number >= 0 and lacking(number):
            item = package.imports[number]
            found[number] = (FATAL, '%s %s' % (item['class_name'], '.'.join(package.import_path(number))),
                             'the parent of %s, and the game does not have it; the game stops when it loads this (Could not find SuperStruct)'
                             % '.'.join(package.export_path(index)))

    def under_one_said(number):
        at = package.imports[number]['outer']
        while at < 0:
            if -at - 1 in found:
                return True
            at = package.imports[-at - 1]['outer']
        return False

    problems = [found[number] for number in sorted(found) if found[number][0] == FATAL or not under_one_said(number)]
    return package, counts, problems


def run_check(args):
    natives = Natives(args.index, use=not args.no_natives)
    if not natives.loaded and not args.no_natives:
        raise Problem(NO_NATIVES + ' --no-natives checks everything else without it.')
    game = Game(args.paks, args.repak, args.cache)
    registry = Registry.load(game, args.registry)
    files = package_files(args.files)
    if not files:
        raise Problem('There is no cooked package in %s.' % ', '.join(args.files))
    loaded = [(path, load_package(path)) for path in files]
    own = {name.lower() for name in (package_name(text) for text in args.own) if name}
    for path, package in loaded:
        name = own_package(path, args.content, package.names)
        if name:
            own.add(name.lower())
    bad = 0
    unseen = 0
    for path, package in loaded:
        package, counts, problems = check(path, game, registry, natives, own, package)
        packages = sum(1 for item in package.imports if item['outer'] == 0)
        print('%s: %d imports: %s, %d packages' % (os.path.basename(path), len(package.imports),
                                                    ', '.join('%d %s' % (count, key) for key, count in counts.items()), packages))
        for level, what, why in problems:
            print('  %-7s %s\n          %s' % (level, what, why))
            unseen += level == UNSEEN
            bad += level != UNSEEN or args.strict_natives
    if natives.note:
        print('note: %s' % natives.note)
    if natives.loaded and not natives.whole:
        print('note: native imports were looked up in %s only, which is not the model of this build, so a miss there is only named. '
              'python scripts\\gamemodel\\native.py makes the full list.' % natives.file)
    if args.verbose:
        print('registry: %s' % registry.source)
        print('native types: %s' % (natives.file if natives.loaded else 'left out'))
    if bad:
        print('result: FAIL, %d problem(s)' % bad)
    elif not natives.loaded:
        print('result: every import that was checked exists in the game; native imports were left out (--no-natives)')
    elif unseen:
        print('result: every import that could be checked exists in the game; the ones named above could not be')
    else:
        print('result: every import exists in the game')
    return 1 if bad else 0


def run_natives(args):
    """Says which list native imports are looked up in, before anything is cooked for it."""
    natives = Natives(args.index)
    if not natives.loaded:
        raise Problem(NO_NATIVES)
    if natives.note:
        print('note: %s' % natives.note)
    print('native types: %s' % natives.file)
    print('whole: %s' % ('yes' if natives.whole else 'no, a miss in it is only named (python scripts\\gamemodel\\native.py makes the full list)'))
    return 0


def run_imports(args):
    for path in args.files:
        package = load_package(path)
        print('%s: %s, %d names, %d imports, %d exports' % (path, 'cooked' if package.cooked else 'editor asset',
                                                           len(package.names), len(package.imports), len(package.exports)))
        for number, item in enumerate(package.imports):
            print('import %s %s' % (item['class_name'], '.'.join(package.import_path(number))))
        for number in range(len(package.exports)):
            print('export %s %s' % (package.export_class(number), '.'.join(package.export_path(number))))
        if args.names:
            for name in package.names:
                print('name %s' % name)
    return 0


def package_files(paths):
    """The files named, and for a folder every .uasset and .umap below it."""
    files = []
    for path in paths:
        if os.path.isdir(path):
            for folder, _, names in os.walk(path):
                files += [os.path.join(folder, name) for name in sorted(names) if name.lower().endswith(HEADS)]
        else:
            files.append(path)
    return files


def run_cooked(args):
    """One line for each package file: cooked, source, unreadable (not a package) or unopened, a tab, the path."""
    for path in package_files(args.files):
        try:
            kind = 'cooked' if load_package(path, tables=False).cooked else 'source'
        except Unopened:
            kind = 'unopened'
        except Problem:
            kind = 'unreadable'
        print('%s\t%s' % (kind, path))
    return 0


def package_name(text):
    """A /Game package name from what a person may type: an object path, a file path, with or without /Game."""
    text = text.strip().replace('\\', '/')
    lower = text.lower()
    if lower.startswith('/game/'):
        text = '/Game/' + text[len('/game/'):]
    else:
        for marker in ('/game/', 'icarus/content/', '/content/'):
            at = lower.rfind(marker)
            if at >= 0:
                text = '/Game/' + text[at + len(marker):]
                break
        else:
            return None
    folder, _, last = text.rpartition('/')
    return folder + '/' + last.split('.', 1)[0]


def editor_modules(engine, project):
    """Lower-case names of the modules the editor has a binary for."""
    found = set()
    roots = [os.path.join(engine, 'Engine', 'Binaries', 'Win64'), os.path.join(project, 'Binaries', 'Win64')]
    for plugins in (os.path.join(engine, 'Engine', 'Plugins'), os.path.join(project, 'Plugins')):
        for folder, folders, _ in os.walk(plugins):
            if os.path.basename(folder) == 'Win64' and os.path.basename(os.path.dirname(folder)) == 'Binaries':
                roots.append(folder)
                folders[:] = []
            elif os.path.basename(folder) in ('Source', 'Content', 'Resources', 'Intermediate'):
                folders[:] = []
    for root in roots:
        for path in glob.glob(os.path.join(root, 'UE4Editor-*.dll')):
            found.add(os.path.basename(path)[len('UE4Editor-'):-4].lower())
    return found


def listed_packages(project):
    """Lower-case /Game names of the game packages that GameFiles.txt says are in the project already."""
    found = set()
    try:
        with open(os.path.join(project, 'GameFiles.txt'), encoding='utf-8-sig') as handle:
            for line in handle:
                line = line.strip()
                if line and not line.startswith(('#', 'build ', 'asked ')) and line.lower().endswith(HEADS):
                    found.add('/game/' + os.path.splitext(line)[0].lower())
    except OSError:
        pass
    return found


def package_of(object_path):
    """The package of /Game/Folder/Asset.Object."""
    folder, _, last = object_path.rpartition('/')
    return folder + '/' + last.split('.', 1)[0]


def run_plan(args):
    game = Game(args.paks, args.repak, args.cache)
    registry = Registry.load(game, args.registry)
    modules = editor_modules(args.engine, args.project) if args.engine else None
    asked, unknown = [], []
    for text in args.packages:
        name = package_name(text)
        if not name or not name.startswith('/Game/'):
            unknown.append({'asked': text, 'why': 'not a /Game path', 'nearest': []})
        elif not text.rstrip().endswith('/') and game.has(name):
            asked.append(game.spelling(name))
        elif game.under(name):
            asked += game.under(name)
        else:
            unknown.append({'asked': text, 'why': 'the game has no such package or folder', 'nearest': game.nearest(name)})
    queue = list(dict.fromkeys(asked))
    if len(queue) > args.limit:
        with open(args.json, 'w', encoding='utf-8') as handle:
            json.dump({'packages': [], 'unknown': unknown, 'over': {'packages': len(queue), 'limit': args.limit}}, handle, indent=1)
        print('That is %d packages and the limit is %d. Name fewer, or raise --limit if you mean it.' % (len(queue), args.limit), file=sys.stderr)
        return 1
    wanted = {name.lower() for name in queue}
    packages, left, lacking = [], {}, {}
    about, edges, lacked = {}, {}, {}
    while queue:
        package = queue.pop(0)
        parts = game.parts(package)
        header = game.header(package)
        packages.append({'package': package, 'asked': package in asked,
                         'files': [{'pak': pak, 'path': path, 'to': path[len('Icarus/Content/'):]} for pak, path in parts]})
        uses = {}
        for number, item in enumerate(header.imports):
            if item['outer'] < 0:
                outer = header.imports[-item['outer'] - 1]
                if outer['outer'] == 0:
                    uses.setdefault(outer['name'], set()).add(item['class_name'])
        scripts = sorted(item['name'] for item in header.imports if item['outer'] == 0 and item['name'].lower().startswith('/script/'))
        if modules is not None:
            for script in scripts:
                if script[len('/Script/'):].lower() not in modules:
                    lacking.setdefault(script, []).append(package)
                    lacked.setdefault(package.lower(), set()).add(script)
        if package in asked:
            about[package] = describe(package, header, registry, modules)
        reached = edges.setdefault(package.lower(), set())
        for target in (item['name'] for item in header.imports if item['outer'] == 0):
            lower = target.lower()
            if lower.startswith('/script/'):
                continue
            if lower.startswith('/game/'):
                reached.add(lower)
            if lower in wanted:
                continue
            if not lower.startswith('/game/'):
                if not lower.startswith('/engine/'):
                    left.setdefault('content of a plugin, which is not copied', []).append(target)
                continue
            if not game.has(target):
                left.setdefault('named by a game package and not in the game', []).append(target)
            elif args.no_imports:
                left.setdefault('imports were not asked for', []).append(target)
            elif args.no_materials and uses.get(target) and all(cls.startswith('Material') for cls in uses[target]):
                left.setdefault('materials were left out', []).append(target)
            elif len(wanted) >= args.limit:
                left.setdefault('over the limit of %d packages' % args.limit, []).append(target)
            else:
                wanted.add(lower)
                queue.append(game.spelling(target))
    planned = {entry['package'].lower() for entry in packages}
    listed = listed_packages(args.project)
    for package, info in about.items():
        seen, stack, lacks = {package.lower()}, [package.lower()], set()
        while stack:
            at = stack.pop()
            lacks.update(lacked.get(at, ()))
            for target in edges.get(at, ()):
                if target not in seen:
                    seen.add(target)
                    stack.append(target)
        info['lacks'] = sorted(lacks)
        above = [package_of(path) for path in info['parents'] if not path.lower().startswith(('/script/', '/engine/'))]
        info['parents_left'] = [name for name in above if name.lower() not in planned and name.lower() not in listed]
    plan = {'packages': packages, 'unknown': unknown, 'about': about,
            'left': {why: sorted(set(names)) for why, names in left.items()},
            'lacking': {script: len(set(names)) for script, names in lacking.items()},
            'registry': registry.source}
    with open(args.json, 'w', encoding='utf-8') as handle:
        json.dump(plan, handle, indent=1)
    print('%d package(s), %d file(s) planned; %d name(s) not found' % (
        len(packages), sum(len(entry['files']) for entry in packages), len(unknown)))
    return 1 if unknown else 0


def describe(package, header, registry, modules):
    """What a person wants to know about a package they asked for: its class, its parents, what the editor lacks.

    can_be_parent only says whether the native class at the end of the parents is in the editor."""
    info = {'objects': [], 'parents': [], 'can_be_parent': None}
    for number, item in enumerate(header.exports):
        if item['outer'] == 0 and not item['name'].startswith('Default__'):
            info['objects'].append('%s %s' % (header.export_class(number), item['name']))
            path = '%s.%s' % (package, item['name'])
            chain = registry.chain(path)
            if chain:
                info['class'] = path
                info['kind'] = header.export_class(number)
                info['parents'] = chain
                native = chain[-1]
                if native.startswith('/Script/') and modules is not None:
                    module = native[len('/Script/'):].split('.', 1)[0]
                    info['can_be_parent'] = module.lower() in modules
                    info['native'] = native
    return info


def run_fetch(args):
    game = Game(args.paks, args.repak, args.cache)
    with open(args.plan, encoding='utf-8') as handle:
        plan = json.load(handle)
    started = time.time()
    count = size = 0
    for entry in plan['packages']:
        for part in entry['files']:
            data = game.read(part['pak'], part['path'])
            target = os.path.join(args.content, part['to'].replace('/', os.sep))
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, 'wb') as handle:
                handle.write(data)
            count += 1
            size += len(data)
    print('%d file(s) copied, %.1f MB, %.1f s' % (count, size / 1e6, time.time() - started))
    return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    verb = argv.pop(0) if argv and argv[0] in ('check', 'natives', 'imports', 'cooked', 'plan', 'fetch') else 'check'
    parser = argparse.ArgumentParser(prog='check_imports.py ' + verb, description=__doc__.split('\n')[0])
    parser.add_argument('--paks', help="the game's Paks folder (found through Steam when left out)")
    parser.add_argument('--repak', default=REPAK)
    parser.add_argument('--cache', default=CACHE, help='where the pak listing and the registry are kept between runs')
    parser.add_argument('--registry', help='assets.json of the game model, a file written by gamemodel\\registry.py --json, '
                                           'or an AssetRegistry.bin, instead of the installed game\'s registry')
    if verb == 'check':
        parser.add_argument('files', nargs='+', help='cooked .uasset or .umap files, or a folder of them')
        parser.add_argument('--content', help='the Content folder the files lie under, which gives each its /Game name')
        parser.add_argument('--own', action='append', default=[], help='a package the mod ships itself (the files given are known already)')
        parser.add_argument('--index', help='a list of native types to look native imports up in, instead of the model\'s native.json')
        parser.add_argument('--no-natives', action='store_true', help='leave native imports out when there is no list of native types')
        parser.add_argument('--strict-natives', action='store_true',
                            help='also fail on what cannot be known: a part of a native default object, and any miss when only the class index is there')
        parser.add_argument('--verbose', action='store_true')
        run = run_check
    elif verb == 'natives':
        parser.add_argument('--index', help='a list of native types, instead of the model\'s native.json')
        run = run_natives
    elif verb in ('imports', 'cooked'):
        parser.add_argument('files', nargs='+')
        if verb == 'imports':
            parser.add_argument('--names', action='store_true', help='the name table as well')
        run = run_imports if verb == 'imports' else run_cooked
    elif verb == 'plan':
        parser.add_argument('packages', nargs='+', help='/Game/Path/Asset, or a folder ending in /')
        parser.add_argument('--json', required=True)
        parser.add_argument('--limit', type=int, default=300, help='the most packages to take in all')
        parser.add_argument('--no-imports', action='store_true', help='only the packages named')
        parser.add_argument('--no-materials', action='store_true', help='leave out packages that are only reached as materials')
        parser.add_argument('--engine', help='the engine folder, to say what the editor lacks')
        parser.add_argument('--project', default=os.path.join(ROOT, 'unreal', 'Icarus'))
        run = run_plan
    else:
        parser.add_argument('plan')
        parser.add_argument('content', help='the Content folder to copy into')
        run = run_fetch
    args = parser.parse_args(argv)
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8', errors='replace')
    lower_priority()
    try:
        return run(args)
    except Problem as problem:
        print(problem, file=sys.stderr)
        return 2
    except Exception:
        traceback.print_exc()
        print('The check itself failed (above). This says nothing about the files it was given.', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
