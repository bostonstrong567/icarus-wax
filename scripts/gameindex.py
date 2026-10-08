#!/usr/bin/env python3
"""Index of the game's classes, written from the model of the game (scripts\\gamemodel) or from a UE4SS object dump.

Commands:
  build                 write build\\game-index\\index.json from the model of the installed build; with --dump,
                        or when there is no model, from the object dump UE4SS writes
  types                 write editor definitions for game objects to wax\\types\\icarus. Names are spelled as the
                        running game spelled them when an index made from a dump (index.dump.json) is beside the
                        index, and a function Wax refuses to call says so. Prints a CHECK line for whatever a
                        person has to look at: a member of `game` declared otherwise, a Wax name in front of a
                        reflected member, two blueprint classes of one name. A game class that Wax gives members
                        to also extends the Wax class that lists them (ALSO_EXTENDS)
  site                  write the data files of the game browser page: every class, struct and enum of the index
                        (--met: only the types a mod meets, which is what `types` writes)
  diff <old> <new>      what changed between two index.json files
  find <text>           search classes and members by name
  needs                 check the names Wax uses (wax\\runtime\\data\\needs.lua) against the index and the tables
"""
import argparse
import difflib
import json
import os
import re
import sys
import time
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUMP = os.path.join(ROOT, "game-data", "ue4ss", "ObjectDump.txt")
INDEX_DIR = os.path.join(ROOT, "build", "game-index")
INDEX = os.path.join(INDEX_DIR, "index.json")
DUMP_INDEX = "index.dump.json"
TYPES_DIR = os.path.join(ROOT, "wax", "types", "icarus")
SITE_DIR = os.path.join(INDEX_DIR, "site")
WAX_TYPES = os.path.join(ROOT, "wax", "types")
LIBRARY_LIST = os.path.join(ROOT, "wax", "runtime", "data", "libraries.lua")
REFUSED_LIST = os.path.join(ROOT, "wax", "runtime", "data", "oversized_functions.lua")
NEEDS = os.path.join(ROOT, "wax", "runtime", "data", "needs.lua")
TABLES_DIR = os.path.join(ROOT, "game-data", "data")
META_STRUCT = "/Script/IcarusUtilities.RowMetadata"

FORMAT = 1
GAME_MODULE = "/Script/Icarus"
OBJECT = "/Script/CoreUObject.Object"
CLASS = "/Script/CoreUObject.Class"
FUNCTION_LIBRARY = "/Script/Engine.BlueprintFunctionLibrary"
SCRIPT_BASE = "/Script/CoreUObject.Object:ExecuteUbergraph"

OBJECT_LINE = re.compile(r"\[([0-9A-Fa-f]+)\] (\S+) (.*?)((?: \[[a-z]+: [^\]]*\])+)\s*$")
VALUE_LINE = re.compile(r"\[0+\] (.*?) \[n: [0-9A-Fa-f]+\] \[v: (-?\d+)\]\s*$")
TAG = re.compile(r"\[([a-z]+): ([^\]]*)\]")
CLASS_TAG = re.compile(r"\[c: ([0-9A-Fa-f]+)\]")
FUNCTION_KINDS = {"Function", "DelegateFunction", "SparseDelegateFunction"}
STRUCT_KINDS = {"ScriptStruct", "UserDefinedStruct"}
ENUM_KINDS = {"Enum", "UserDefinedEnum"}
REFERENCE_TAGS = {"Object": "pc", "WeakObject": "pc", "LazyObject": "pc", "SoftObject": "pc",
                  "Class": "mc", "SoftClass": "mc", "Interface": "ic", "Struct": "ss", "Enum": "em"}
OBJECT_TYPES = {"Object", "WeakObject", "LazyObject", "SoftObject", "Interface"}
CLASS_TYPES = {"Class", "SoftClass"}
INTEGER_TYPES = {"Int", "Int8", "Int16", "Int64", "Byte", "UInt16", "UInt32", "UInt64"}
DELEGATE_TYPES = {"Delegate", "MulticastDelegate", "MulticastInlineDelegate", "MulticastSparseDelegate"}
SIZES = {"Bool": 1, "Byte": 1, "Int8": 1, "Enum": 1, "Int16": 2, "UInt16": 2, "Int": 4, "UInt32": 4, "Float": 4,
         "Int64": 8, "UInt64": 8, "Double": 8, "Name": 8, "Object": 8, "Class": 8, "WeakObject": 8, "Str": 16,
         "Array": 16, "Interface": 16, "Delegate": 16, "MulticastInlineDelegate": 16, "MulticastSparseDelegate": 1,
         "Text": 24, "LazyObject": 28, "FieldPath": 32, "SoftObject": 40, "SoftClass": 40, "Map": 80, "Set": 80}
CALL_BUFFER = 512
COMPILER_LOCAL = re.compile(r"^(CallFunc_|K2Node_|Temp_|___|__Local__)")
UE4SS_SIMPLE = {"int32": "Int", "int64": "Int64", "int16": "Int16", "int8": "Int8", "uint8": "Byte", "uint16": "UInt16",
                "uint32": "UInt32", "uint64": "UInt64", "float": "Float", "double": "Double", "boolean": "Bool",
                "bool": "Bool", "FName": "Name", "FString": "Str", "FText": "Text"}
UE4SS_WRAPPERS = {"TSoftObjectPtr": "SoftObject", "TWeakObjectPtr": "WeakObject", "TLazyObjectPtr": "LazyObject",
                  "TSubclassOf": "Class", "TSoftClassPtr": "SoftClass", "TScriptInterface": "Interface"}

# Members a blueprint compiler adds. Nobody scripts against them, so types and site leave them out unless asked.
INTERNAL_MEMBER = re.compile(r"^(UberGraphFrame$|ExecuteUbergraph|AnimGraphNode_|AnimBlueprintExtension_|__AnimBlueprintMutables$"
                             r"|K2Node_|CallFunc_|Temp_|__CustomProperty_)")
LUA_KEYWORDS = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local",
                "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"}
LUA_TYPE_NAMES = {"any", "nil", "boolean", "number", "integer", "string", "table", "function", "thread", "userdata",
                  "lightuserdata", "unknown", "self", "never"}
INSTANCE_MEMBERS = {"Name", "ClassName", "FullName", "Parent", "Raw", "Get", "Set", "Call", "IsValid", "IsA",
                    "GetClassChain", "GetMembers", "GetParent", "GetChildren", "FindFirstChild", "FindFirstChildOfClass",
                    "FindFirstChildWhichIsA", "GetDescendants", "GetAttribute", "GetAttributes", "SetAttribute",
                    "GetAttributeChangedSignal", "AddTag", "RemoveTag", "HasTag", "GetTags"}
INSTANCE = "WaxInstance"
DELEGATE = "GameDelegate"
CLASS_LIST = "classes.txt"
GENERATED_BY = "-- Generated by scripts\\gameindex.py"
GENERATED = GENERATED_BY + " from the index of the game's classes. Changes here are lost on the next run."
TYPES_FILE_LIMIT = 300 * 1024
SITE_CHUNK_LIMIT = 400 * 1024

# How Wax reaches each member of `game` (wax\runtime\Scripts\wax\engine\game.lua): a start class, then property reads.
ENTRY_POINTS = [
    ("Engine", [], "process"),
    ("Viewport", ["GameViewport"], "process"),
    ("World", ["GameViewport", "World"], "map"),
    ("GameInstance", ["GameViewport", "GameInstance"], "process"),
    ("GameState", ["GameViewport", "World", "GameState"], "map"),
    ("GameMode", ["GameViewport", "World", "AuthorityGameMode"], "map"),
    ("LocalPlayer", ["GameViewport", "GameInstance", "LocalPlayers", "PlayerController"], "map"),
    ("Character", ["GameViewport", "GameInstance", "LocalPlayers", "PlayerController", "Pawn"], "map"),
]
ENTRY_START = "/Script/Engine.Engine"
OPTIONAL_ENTRIES = {"GameMode", "Character"}

# Blueprint classes that share a name with another one and keep the plain editor name: path in lower case -> name.
# The other class of the pair is told apart by its folder. `types` prints a CHECK line for a pair that is not here.
PLAIN_NAMES = {
    "/game/ui/umg_playername.umg_playername_c": "UMG_PlayerName_C",
    "/game/ui/windows/umg_spawnblocker.umg_spawnblocker_c": "UMG_Spawnblocker_C",
    "/game/ass/cre/roat/old/sk_cre_roat_dead_animbp.sk_cre_roat_dead_animbp_c": "SK_CRE_Roat_Dead_AnimBP_C",
    "/game/bp/quests/prometheus/e/story2/bp_icesheet_blocker.bp_icesheet_blocker_c": "BP_Icesheet_Blocker_C",
}

# The ruling: no Wax name replaces a reflected member of the game, beyond these two.
ALWAYS_ACCEPTED = {"Name", "Parent"}
# Clashes that were there before the rule was checked, as (Wax class, member, the game class that has it too).
# They wait for the owner's word: `types` still prints a CHECK line for each, and a clash that is not here fails the tests.
ACCEPTED_CLASHES = {
    ("WaxInstance", "ClassName", "/Game/BP/Tools/CheatFunctions/Widgets/FlammableComponentClassRow.FlammableComponentClassRow_C"),
    ("WaxInstance", "Get", "/Script/MediaAssets.MediaPlaylist"),
    ("WaxInstance", "GetChildren", "/Script/LiveLink.LiveLinkBlueprintLibrary"),
    ("WaxInstance", "GetParent", "/Script/LiveLink.LiveLinkBlueprintLibrary"),
    ("WaxInstance", "GetParent", "/Script/UMG.Widget"),
    ("WaxInstance", "GetParent", "/Script/VariantManagerContent.Variant"),
    ("WaxInstance", "GetParent", "/Script/VariantManagerContent.VariantSet"),
    ("WaxInstance", "GetTags", "/Game/UI/Debug/UMG_InspectionToolPopup.UMG_InspectionToolPopup_C"),
    ("WaxInstance", "GetTags", "/Script/Sentry.SentryScope"),
    ("WaxInstance", "HasTag", "/Script/GameplayTags.BlueprintGameplayTagLibrary"),
    ("WaxInstance", "IsValid", "/Game/BP/AI/GOAP/EQS/BP_NavigationCheckpoint.BP_NavigationCheckpoint_C"),
    ("WaxInstance", "IsValid", "/Script/AssetRegistry.AssetRegistryHelpers"),
    ("WaxInstance", "IsValid", "/Script/Engine.KismetSystemLibrary"),
    ("WaxInstance", "IsValid", "/Script/Icarus.FlagsMultiRowHandleLibrary"),
    ("WaxInstance", "IsValid", "/Script/Icarus.QuestModifiersMultiRowHandleLibrary"),
    ("WaxInstance", "IsValid", "/Script/NavigationSystem.NavigationPath"),
    ("WaxInstance", "RemoveTag", "/Script/Sentry.SentryScope"),
    ("WaxInstance", "RemoveTag", "/Script/Sentry.SentrySubsystem"),
}

# Game classes whose Instances Wax gives members to, and the Wax classes that list those members (what the runtime
# registers in wax\runtime\Scripts\wax\world). The written class extends them before its own parent: the editor
# searches parents in order, and behind the game's parents waits WaxInstance, which answers any name with `any`.
ALSO_EXTENDS = {
    "/Script/Icarus.IcarusCharacter": ("WaxCharacter",),
    "/Script/Icarus.IcarusPlayerCharacter": ("WaxPlayerCharacter", "WaxPlayerItems"),
    "/Script/Icarus.IcarusNPCCharacter": ("WaxCreatureMembers",),
    "/Script/Icarus.IcarusPawn": ("WaxCreatureMembers",),
    "/Script/Icarus.Inventory": ("WaxInventory",),
    "/Script/Engine.PlayerState": ("WaxPlayer",),
}


def fail(message):
    sys.exit(message)


def leaf(path):
    return re.split(r"[.:]", path)[-1]


def package_of(path):
    return path.split(".", 1)[0]


def is_zero(address):
    return address.strip("0") == ""


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as file:
        file.write(text)


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


class Dump:
    def __init__(self):
        self.structs = {}                   # address -> [kind, path, parent address]
        self.enums = {}                     # address -> [kind, path, values]
        self.functions = {}                 # address -> [kind, path, outer address, native pointer]
        self.properties = {}                # address -> [kind, path, owner address, offset, tags]
        self.owned = defaultdict(list)      # owner address -> property addresses in dump order
        self.instances = defaultdict(int)   # class address -> objects of exactly that class
        self.lines = 0


def read_dump(path):
    dump = Dump()
    enum = None
    recent = None
    with open(path, encoding="utf-8", errors="replace") as file:
        for line in file:
            dump.lines += 1
            if line.startswith("[0000"):
                value = VALUE_LINE.match(line)
                if value:
                    if enum is not None:
                        enum.append((value.group(1).split("::")[-1], int(value.group(2))))
                    continue
            match = OBJECT_LINE.match(line)
            if not match:
                continue
            address, kind, path, tags = match.groups()
            enum = None
            if " [owr: " in tags or kind in FUNCTION_KINDS:
                found = dict(TAG.findall(tags))
                owner = found.get("owr") or found.get("or", "")
                # A class kind the dump gives no parent for is known by the members that follow it.
                if recent and recent[0] == owner and owner not in dump.structs:
                    dump.structs[owner] = [recent[1], recent[2], ""]
                if "owr" in found:
                    dump.properties[address] = [kind, path, owner, int(found.get("o", "0"), 16), found]
                    dump.owned[owner].append(address)
                else:
                    dump.functions[address] = [kind, path, owner, found.get("f", "")]
                continue
            recent = None
            if leaf(path).startswith("Default__"):
                continue
            if kind in ENUM_KINDS:
                enum = []
                dump.enums[address] = [kind, path, enum]
            elif kind in STRUCT_KINDS or " [sps: " in tags:
                dump.structs[address] = [kind, path, dict(TAG.findall(tags)).get("sps", "")]
            elif kind != "Package":
                owner = CLASS_TAG.search(tags)
                if owner and "Default__" not in path:
                    dump.instances[owner.group(1)] += 1
                    recent = (address, kind, path)
    return dump


# The types folder UE4SS writes beside the dump has what the dump leaves out: parameters, byte enums, set elements.

def split_generic(text):
    text = text.strip()
    if not text.endswith(">") or "<" not in text:
        return text, []
    head, inner = text[:-1].split("<", 1)
    parts, depth, start = [], 0, 0
    for i, char in enumerate(inner):
        if char == "<":
            depth += 1
        elif char == ">":
            depth -= 1
        elif char == "," and depth == 0:
            parts.append(inner[start:i].strip())
            start = i + 1
    parts.append(inner[start:].strip())
    return head.strip(), parts


def read_ue4ss_types(folder):
    if not folder or not os.path.isdir(folder):
        return None
    fields, calls = {}, {}
    declared = re.compile(r"---@class (\S+)")
    field = re.compile(r"---@field (\S+) (.+)")
    param = re.compile(r"---@param (\S+) (.+)")
    plain = re.compile(r"function ([^\s:(]+):([^\s(]+)\((.*)\) end")
    keyed = re.compile(r"(\S+?)\['(.+)'\] = function\((.*)\) end")
    for name in sorted(os.listdir(folder)):
        if not name.endswith(".lua"):
            continue
        owner, params, result = None, [], None
        with open(os.path.join(folder, name), encoding="utf-8", errors="replace") as file:
            for line in file:
                if line.startswith("---@field "):
                    found = field.match(line)
                    if found and owner:
                        fields[(owner, found.group(1))] = found.group(2).strip()
                elif line.startswith("---@param "):
                    found = param.match(line)
                    if found:
                        params.append((found.group(1), found.group(2).strip()))
                elif line.startswith("---@return "):
                    result = line[11:].strip()
                elif line.startswith("---@class "):
                    owner = declared.match(line).group(1)
                    params, result = [], None
                elif "function" in line:
                    found, skip = plain.match(line), 0
                    if not found:
                        found, skip = keyed.match(line), 1
                    if found:
                        names = [n.strip() for n in found.group(3).split(",") if n.strip()][skip:]
                        if len(names) == len(params):
                            calls[(found.group(1), found.group(2))] = (params, result)
                    params, result = [], None
    return fields, calls


def same_name(a, b):
    return re.sub(r"[^0-9A-Za-z]", "", a).lower() == re.sub(r"[^0-9A-Za-z]", "", b).lower()


class Linker:
    def __init__(self, dump, extra):
        self.dump = dump
        self.fields, self.calls = extra if extra else ({}, {})
        self.has_extra = extra is not None
        self.path = {}
        self.by_leaf = defaultdict(lambda: defaultdict(list))
        for address, record in dump.structs.items():
            self.path[address] = record[1]
            self.by_leaf["struct" if record[0] in STRUCT_KINDS else "class"][leaf(record[1])].append(record[1])
        for address, record in dump.enums.items():
            self.path[address] = record[1]
            self.by_leaf["enum"][leaf(record[1])].append(record[1])
        for address, record in dump.functions.items():
            self.path[address] = record[1]
        self.parent = {r[1]: self.path.get(r[2]) for r in dump.structs.values()}
        self.sizes = {}
        self.script_pointer = self.find_script_pointer()
        self.sources = defaultdict(int)
        self.unresolved = 0

    def find_script_pointer(self):
        counts = defaultdict(int)
        for kind, path, _outer, pointer in self.dump.functions.values():
            if path == SCRIPT_BASE:
                return pointer
            if kind == "Function" and not path.startswith("/Script/"):
                counts[pointer] += 1
        return max(counts, key=counts.get) if counts else ""

    def inherits(self, path, ancestor):
        for _ in range(64):
            if not path:
                return False
            if path == ancestor:
                return True
            path = self.parent.get(path)
        return False

    def lookup(self, group, name, near):
        found = self.by_leaf[group].get(name, [])
        if len(found) == 1:
            return found[0]
        same = [p for p in found if package_of(p) == near]
        return same[0] if len(same) == 1 else None

    def from_text(self, text, near):
        head, parts = split_generic(text)
        if head in UE4SS_SIMPLE:
            return {"type": UE4SS_SIMPLE[head]}
        if head in UE4SS_WRAPPERS and parts:
            inner = self.from_text(parts[0], near)
            described = {"type": UE4SS_WRAPPERS[head]}
            if inner and "ref" in inner:
                described["ref"] = inner["ref"]
            return described
        enum = self.lookup("enum", head.split("::")[0], near)
        if enum:
            return {"type": "Enum", "ref": enum}
        struct = self.lookup("struct", head[1:], near) if head[:1] == "F" else None
        if struct:
            return {"type": "Struct", "ref": struct}
        owner = self.lookup("class", head[1:], near) if head[:1] in ("U", "A", "I") else None
        if owner:
            return {"type": "Object", "ref": owner}
        return None

    def refine(self, described, text, near):
        if not text:
            return
        head, parts = split_generic(text)
        kind = described["type"]
        if kind == "Byte":
            enum = self.lookup("enum", (parts[0] if head == "TEnumAsByte" and parts else head).split("::")[0], near)
            if enum:
                described["enum"] = enum
        elif kind == "Array" and parts and "inner" in described:
            self.refine(described["inner"], parts[0], near)
        elif kind == "Set" and parts:
            inner = self.from_text(parts[0], near)
            if inner:
                described["inner"] = inner
        elif kind == "Map" and len(parts) == 2:
            for side, part in (("key", parts[0]), ("value", parts[1])):
                if side in described:
                    self.refine(described[side], part, near)

    def describe(self, address):
        kind, _path, _owner, _offset, tags = self.dump.properties[address]
        kind = kind[:-8] if kind.endswith("Property") else kind
        described = {"type": kind}
        tag = REFERENCE_TAGS.get(kind)
        if tag:
            target = self.path.get(tags.get(tag, ""))
            if target:
                described["ref"] = target
            elif not is_zero(tags.get(tag, "0")):
                self.unresolved += 1
        elif kind == "Array":
            if tags.get("ai") in self.dump.properties:
                described["inner"] = self.describe(tags["ai"])
        elif kind == "Map":
            for side, key in (("key", "kp"), ("value", "vp")):
                if tags.get(key) in self.dump.properties:
                    described[side] = self.describe(tags[key])
        elif kind in DELEGATE_TYPES:
            target = self.path.get(tags.get("df", ""))
            if target:
                described["ref"] = target
        return described

    def size_of(self, described):
        if described["type"] == "Struct":
            return self.sizes.get(described.get("ref"), 1)
        return SIZES.get(described["type"], 1)

    def member(self, address, owner_path, text=None):
        _kind, path, _owner, offset, tags = self.dump.properties[address]
        name = path[len(owner_path) + 1:] if path.startswith(owner_path + ":") else path.rsplit(":", 1)[-1]
        record = {"name": name}
        record.update(self.describe(address))
        self.refine(record, text, package_of(owner_path))
        record["offset"] = offset
        if "bm" in tags:
            record["mask"] = int(tags["bm"], 16)
        return record

    def keys_for(self, owner_path, is_struct):
        name = leaf(owner_path)
        return ["F" + name] if is_struct else ["U" + name, "A" + name, "I" + name]

    def members(self, address, path, is_struct):
        keys = self.keys_for(path, is_struct)
        out, end = [], 0
        for child in self.dump.owned.get(address, ()):
            name = self.dump.properties[child][1].rsplit(":", 1)[-1]
            text = next((self.fields[(k, name)] for k in keys if (k, name) in self.fields), None)
            record = self.member(child, path, text)
            end = max(end, record["offset"] + self.size_of(record))
            out.append(record)
        return out, end

    def function(self, address, owner_path, owner_is_class, inherited):
        kind, path, _outer, pointer = self.dump.functions[address]
        name = path[len(owner_path) + 1:] if path.startswith(owner_path + ":") else leaf(path)
        children = self.dump.owned.get(address, ())
        scripted = pointer == self.script_pointer and kind == "Function" and not owner_path.startswith("/Script/")
        names = [self.dump.properties[c][1].rsplit(":", 1)[-1] for c in children]
        known = next((self.calls[(k, name)] for k in self.keys_for(owner_path, False) if (k, name) in self.calls), None)
        keep, source = len(children), "dump"
        if scripted and children:
            keep, source = self.script_parameters(name, names, known, inherited)
        self.sources[source] += 1
        texts = dict(known[0]) if known else {}
        record = {"name": name, "params": []}
        frame = 0
        for index, child in enumerate(children):
            if index >= keep:
                frame = max(frame, self.dump.properties[child][3] + self.size_of(self.describe(child)))
                continue
            item = self.member(child, path)
            text = next((t for n, t in texts.items() if same_name(n, item["name"])), None)
            if item["name"] == "ReturnValue" and known:
                text = known[1]
            self.refine(item, text, package_of(owner_path))
            frame = max(frame, item.pop("offset") + self.size_of(item))
            item.pop("mask", None)
            if item["name"] == "ReturnValue":
                del item["name"]
                record["returns"] = item
            else:
                record["params"].append(item)
        flags = []
        if kind != "Function" or name.endswith("__DelegateSignature"):
            flags.append("delegate")
        elif pointer != self.script_pointer:
            flags.append("native")
        elif owner_path.startswith("/Script/"):
            flags.append("event")
        else:
            flags.append("blueprint")
        if owner_is_class and self.inherits(owner_path, FUNCTION_LIBRARY):
            flags.append("static")
        if name.startswith("ExecuteUbergraph"):
            flags.append("internal")
        if any(p.get("ref") == "/Script/Engine.LatentActionInfo" for p in record["params"]):
            flags.append("latent")
        if source == "guess":
            flags.append("unsure")
        if frame > CALL_BUFFER:
            flags.append("oversized")
            record["frame"] = frame
        record["flags"] = flags
        if len(children) > keep:
            record["locals"] = len(children) - keep
        return record

    def script_parameters(self, name, names, known, inherited):
        """How many of a blueprint function's properties are parameters. The rest are its local variables."""
        if known:
            listed = [n for n, _ in known[0]]
            mine = [n for n in names if n != "ReturnValue"][:len(listed)]
            if len(mine) == len(listed) and all(same_name(a, b) for a, b in zip(mine, listed)):
                count = len(listed)
                if "ReturnValue" in names and names.index("ReturnValue") <= count:
                    count += 1
                return count, "ue4ss"
        if name.startswith("ExecuteUbergraph") and names[0] == "EntryPoint":
            return 1, "entry"
        above = inherited.get(name)
        if above and names[:len(above)] == above:
            return len(above), "inherited"
        if "ReturnValue" in names:
            return names.index("ReturnValue") + 1, "return"
        count = 0
        while count < len(names) and not COMPILER_LOCAL.match(names[count]):
            count += 1
        return count, ("guess" if count else "dump")


def parents_first(dump):
    order, done = [], set()
    for start in dump.structs:
        chain = []
        while start in dump.structs and start not in done:
            done.add(start)
            chain.append(start)
            start = dump.structs[start][2]
        order.extend(reversed(chain))
    return order


def link(dump, extra, source):
    linker = Linker(dump, extra)
    classes, structs, enums, delegates = [], [], [], []
    functions_of = defaultdict(list)
    for address, record in dump.functions.items():
        functions_of[record[2]].append(address)

    order = parents_first(dump)
    fields = {}
    for address in order:
        kind, path, parent = dump.structs[address]
        if kind in STRUCT_KINDS:
            fields[address], end = linker.members(address, path, True)
            linker.sizes[path] = max(end, linker.sizes.get(linker.path.get(parent), 0), 1)
    signatures = {}
    for address in order:
        kind, path, parent = dump.structs[address]
        parent_path = linker.path.get(parent)
        record = {"name": leaf(path), "path": path, "package": package_of(path), "native": path.startswith("/Script/")}
        if parent_path:
            record["parent"] = parent_path
        if kind in STRUCT_KINDS:
            record["fields"] = fields[address]
            structs.append(record)
            continue
        record["kind"] = kind
        record["properties"], _ = linker.members(address, path, False)
        inherited = dict(signatures.get(parent_path, {}))
        record["functions"] = []
        for function in functions_of.get(address, ()):
            made = linker.function(function, path, True, inherited)
            record["functions"].append(made)
            if "unsure" not in made["flags"]:
                inherited[made["name"]] = [p["name"] for p in made["params"]] + (["ReturnValue"] if "returns" in made else [])
        signatures[path] = inherited
        if dump.instances.get(address):
            record["instances"] = dump.instances[address]
        classes.append(record)

    for kind, path, values in dump.enums.values():
        enums.append({"name": leaf(path), "path": path, "package": package_of(path),
                      "native": path.startswith("/Script/"), "values": [list(v) for v in values]})
    for address, (kind, path, outer, _pointer) in dump.functions.items():
        if outer not in dump.structs:
            made = linker.function(address, package_of(path), False, {})
            made.update(path=path, package=package_of(path))
            delegates.append(made)

    orphans = sum(1 for p in dump.properties.values()
                  if p[2] not in dump.structs and p[2] not in dump.functions and p[2] not in dump.properties)
    for group in (classes, structs, enums, delegates):
        group.sort(key=lambda r: r["path"])
    counts = {
        "classes": len(classes),
        "native_classes": sum(1 for c in classes if c["native"]),
        "blueprint_classes": sum(1 for c in classes if not c["native"]),
        "structs": len(structs),
        "enums": len(enums),
        "enum_values": sum(len(e["values"]) for e in enums),
        "properties": sum(len(c["properties"]) for c in classes),
        "struct_fields": sum(len(s["fields"]) for s in structs),
        "functions": sum(len(c["functions"]) for c in classes),
        "parameters": sum(len(f["params"]) for c in classes for f in c["functions"]),
        "delegates": len(delegates),
    }
    source = dict(source, lines=dump.lines, ue4ss_types=linker.has_extra, parameter_sources=dict(linker.sources),
                  unresolved_references=linker.unresolved, properties_without_owner=orphans)
    return {"format": FORMAT, "source": source, "counts": counts,
            "classes": classes, "structs": structs, "enums": enums, "delegates": delegates}


def write_index(index, path):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as file:
        file.write('{"format":%d,\n"source":%s,\n"counts":%s' % (index["format"], compact(index["source"]), compact(index["counts"])))
        for group in ("classes", "structs", "enums", "delegates"):
            file.write(',\n"%s":[\n' % group)
            file.write(",\n".join(compact(record) for record in index[group]))
            file.write("\n]")
        file.write("\n}\n")


def load_index(path):
    if not os.path.isfile(path):
        fail(f"No index at {path}. Run: python scripts\\gameindex.py build")
    with open(path, encoding="utf-8") as file:
        index = json.load(file)
    if index.get("format") != FORMAT:
        fail(f"{path} was written by another version of this tool. Run build again.")
    return index


def build_index(dump_path, types_folder=None):
    if not os.path.isfile(dump_path):
        fail(f"No object dump at {dump_path}.")
    if types_folder is None:
        types_folder = os.path.join(os.path.dirname(os.path.abspath(dump_path)), "types")
    stat = os.stat(dump_path)
    source = {"dump": os.path.basename(dump_path), "bytes": stat.st_size,
              "written": time.strftime("%Y-%m-%d %H:%M", time.localtime(stat.st_mtime))}
    return link(read_dump(dump_path), read_ue4ss_types(types_folder), source)


def folded(name, names, fold):
    """The name as the list spells it: itself when listed, else the one that differs only in letter case when fold is set."""
    if not fold or name in names:
        return name
    low = name.lower()
    return next((other for other in names if other.lower() == low), name)


def same_path(path):
    """A path as lists keyed by it are compared: lower case, spaces at the end dropped."""
    return path.strip().lower()


class Game:
    def __init__(self, index):
        self.index = index
        # A model spells names as the game's files do and a dump as the running game happened to meet them. The
        # engine ignores letter case, and so does Wax's own check in the game, so names are found without it here.
        self.fold = True
        self.classes = {c["path"]: c for c in index["classes"]}
        self.structs = {s["path"]: s for s in index["structs"]}
        self.enums = {e["path"]: e for e in index["enums"]}
        self.delegates = {d["path"]: d for d in index["delegates"]}
        for owner in index["classes"]:
            for function in owner["functions"]:
                if "delegate" in function["flags"]:
                    self.delegates[owner["path"] + ":" + function["name"]] = function

    def record(self, path):
        return self.classes.get(path) or self.structs.get(path) or self.enums.get(path)

    def kind(self, path):
        return "class" if path in self.classes else "struct" if path in self.structs else "enum" if path in self.enums else None

    def ancestors(self, path):
        seen = []
        record = self.record(path)
        while record and record.get("parent") and record["parent"] not in seen:
            seen.append(record["parent"])
            record = self.record(record["parent"])
        return seen

    def inherits(self, path, ancestor):
        return path == ancestor or ancestor in self.ancestors(path)

    def property(self, path, name):
        """The property of that name on a class or one above it: spelled exactly, else without letter case."""
        owners = [path] + self.ancestors(path)
        for same in (lambda other: other == name, lambda other: other.lower() == name.lower()):
            for owner in owners:
                for item in self.classes.get(owner, {}).get("properties", ()):
                    if same(item["name"]):
                        return item
        return None

    def descendants(self):
        """{class path: every class built on it}."""
        if not hasattr(self, "_built_on"):
            built = defaultdict(list)
            for path in self.classes:
                for ancestor in self.ancestors(path):
                    built[ancestor].append(path)
            self._built_on = built
        return self._built_on


def is_internal(name, flags=()):
    return bool(INTERNAL_MEMBER.match(name)) or "delegate" in flags or "internal" in flags


def visible_members(record, everything):
    """Properties and functions worth showing, by name. A function hides a property of the same name, as it does in the game."""
    functions = {}
    for function in record.get("functions", ()):
        if everything or not is_internal(function["name"], function["flags"]):
            functions.setdefault(function["name"], function)
    properties = {}
    for item in record.get("properties", record.get("fields", ())):
        if item["name"] not in functions and (everything or not is_internal(item["name"])):
            properties.setdefault(item["name"], item)
    return properties, functions


def references(described, out):
    for key in ("ref", "enum"):
        if key in described and described["type"] not in DELEGATE_TYPES:
            out.add(described[key])
    if described["type"] in CLASS_TYPES:
        out.add(CLASS)
    for key in ("inner", "key", "value"):
        if key in described:
            references(described[key], out)


def choose(game, everything):
    """The types a modder meets: the game module, loaded blueprints, every function library, and whatever those inherit from or mention."""
    if everything:
        return set(game.classes) | set(game.structs) | set(game.enums)
    queue = [p for p, c in game.classes.items() if c["package"] == GAME_MODULE or p.startswith("/Game/")
             or game.inherits(p, FUNCTION_LIBRARY)]
    chosen = set()
    while queue:
        path = queue.pop()
        record = game.record(path)
        if path in chosen or record is None:
            continue
        chosen.add(path)
        found = set()
        if record.get("parent"):
            found.add(record["parent"])
        properties, functions = visible_members(record, False)
        for item in properties.values():
            references(item, found)
        for function in functions.values():
            for item in function["params"]:
                references(item, found)
            if "returns" in function:
                references(function["returns"], found)
        queue.extend(found - chosen)
    return chosen


def identifier(name):
    text = re.sub(r"[^0-9A-Za-z_]", "_", name)
    if not text or text[0].isdigit() or text in LUA_KEYWORDS:
        text = "_" + text
    return text


DECLARED = re.compile(r"^---@(class|alias|enum)\s+(?:\([^)]*\)\s*)?([\w.]+)(?:<[^>]*>)?(?:\s*:\s*(.*))?")
FIELD = re.compile(r"^---@field\s+(?:(?:public|private|protected|package)\s+)?(?:\[\"([^\"]+)\"\]|(\w+))\s")


class WaxApi:
    """What Wax's own definitions (wax\\types\\*.lua) declare.

    classes is {class name: {"file", "parents", "members": {member: file}}}: a class's ---@field lines and the
    functions of the table that stands for it. other holds the aliases and enums.
    """

    def __init__(self, folder):
        self.classes, self.other = {}, set()
        names = sorted(name for name in os.listdir(folder) if name.endswith(".lua")) if os.path.isdir(folder) else []
        for name in names:
            with open(os.path.join(folder, name), encoding="utf-8", errors="replace") as file:
                self.read(name, file.read().splitlines())

    def read(self, file, lines):
        starts = []
        for number, line in enumerate(lines):
            found = DECLARED.match(line)
            if not found:
                continue
            if found.group(1) == "class":
                starts.append((number, found.group(2), found.group(3)))
            else:
                self.other.add(found.group(2))
        for place, (start, name, parents) in enumerate(starts):
            end = starts[place + 1][0] if place + 1 < len(starts) else len(lines)
            block = lines[start:end]
            entry = self.classes.setdefault(name, {"file": file, "parents": [], "members": {}})
            for parent in re.split(r"\s*,\s*", parents or ""):
                parent = parent.strip()
                if re.fullmatch(r"[\w.]+", parent) and parent not in entry["parents"]:
                    entry["parents"].append(parent)
            for line in block:
                field = FIELD.match(line)
                if field:
                    entry["members"].setdefault(field.group(1) or field.group(2), file)
            # The table that stands for the class is the statement right under its annotations.
            under = next((line for line in block[1:] if not line.startswith("---")), "")
            local = re.match(r"local (\w+) = \{\}", under)
            if local:
                for line in block:
                    function = re.match(rf"function {local.group(1)}[:.](\w+)\(", line)
                    if function:
                        entry["members"].setdefault(function.group(1), file)

    def names(self):
        return set(self.classes) | self.other

    def above(self, name):
        """A Wax class and the Wax classes it is built on, itself first."""
        seen, queue = [], [name]
        while queue:
            one = queue.pop(0)
            if one in self.classes and one not in seen:
                seen.append(one)
                queue.extend(self.classes[one]["parents"])
        return seen

    def instance_members(self):
        """The member names every Instance has. A game class does not declare those again."""
        found = set(self.classes.get(INSTANCE, {}).get("members", ()))
        return found or set(INSTANCE_MEMBERS)


def declared_names(folder):
    return WaxApi(folder).names()


class Names:
    """One editor type name per class, struct and enum. Two things with the same name are told apart by their folder.

    taken are names that may not be used. A name in shared is a class Wax's own definitions add members to: the
    game class of that name keeps it, and added_to says which class that was.
    """

    def __init__(self, game, taken=(), shared=()):
        self.of, self.added_to = {}, {}
        used = set(LUA_TYPE_NAMES) | set(taken) | {INSTANCE, DELEGATE}
        free = set(shared) - {INSTANCE, DELEGATE}
        # Game names are compared without letter case; Lua's own type names are not game names.
        spoken = set()
        ranked = [(rank, record) for rank, group in enumerate(("classes", "structs", "enums")) for record in game.index[group]]
        ranked.sort(key=lambda item: (item[0], item[1]["path"].lower() not in PLAIN_NAMES, not item[1]["native"], item[1]["path"]))
        for rank, record in ranked:
            base = PLAIN_NAMES.get(record["path"].lower()) or identifier(record["name"])
            folders = [identifier(part) for part in record["package"].strip("/").split("/")]
            folders = folders[1:] if record["native"] else folders[:-1]
            name, depth = base, 0
            while (name in used and not (rank == 0 and name in free)) or name.lower() in spoken:
                depth += 1
                name = f"{base}__{'_'.join(folders[-depth:])}" if depth <= len(folders) else f"{base}__{depth}"
            if name in free:
                free.discard(name)
                self.added_to[name] = record["path"]
            used.add(name)
            spoken.add(name.lower())
            self.of[record["path"]] = name


def names_for(game, api):
    """Names with Wax's own names kept out, except the classes Wax adds members to."""
    classes = {identifier(record["name"]) for record in game.index["classes"]}
    shared = {name for name in api.classes if name in classes}
    return Names(game, api.names() - shared, shared)


NUMBERED = re.compile(r"(.+)_(0|[1-9]\d*)$", re.S)


class Spelling:
    """How the running game spelled names, by an index made from an object dump.

    The model spells a name as the game's files do. The game keeps one spelling for a name, the first it met,
    whatever follows the name as _<number>; and the export tool drops a space at the end of a name.
    """

    def __init__(self, dumped):
        self.written = (dumped.get("source") or {}).get("written")
        self.bases, self.members, self.paths = {}, {}, set()
        for group, keys in (("classes", ("properties", "functions")), ("structs", ("fields",)), ("enums", ())):
            for record in dumped[group]:
                self.note(record["name"])
                self.paths.add(record["path"].lower())
                own = self.members.setdefault(record["path"].lower(), {})
                for key in keys:
                    for item in record[key]:
                        self.note(item["name"])
                        own.setdefault(item["name"].strip().lower(), item["name"])

    @staticmethod
    def split(name):
        found = NUMBERED.match(name)
        return (found.group(1), "_" + found.group(2)) if found else (name, "")

    def note(self, name):
        base = self.split(name)[0]
        self.bases.setdefault(base.lower(), base)

    def name(self, name):
        base, number = self.split(name)
        return self.bases.get(base.lower(), base) + number

    def member(self, path, name):
        """A member's name: the dump's own for that class when it holds one, else by the spelling of the name anywhere."""
        found = self.members.get(path.lower(), {}).get(name.strip().lower())
        return found if found is not None else self.name(name)

    def holds(self, path):
        return path.lower() in self.paths


def respelled(index, spelling):
    """The index with class, struct, enum and member names as the running game spelled them. Paths stay as they are."""
    if spelling is None or "dump" in index["source"]:
        return index
    out = dict(index)
    for group, keys in (("classes", ("properties", "functions")), ("structs", ("fields",)), ("enums", ())):
        records = []
        for record in index[group]:
            record = dict(record, name=spelling.name(record["name"]))
            for key in keys:
                record[key] = [dict(item, name=spelling.member(record["path"], item["name"])) for item in record[key]]
            records.append(record)
        out[group] = records
    return out


def dump_spelling(index_path):
    """The spelling of the index made from an object dump that sits beside an index, or None when there is none."""
    path = os.path.join(os.path.dirname(os.path.abspath(index_path)), DUMP_INDEX)
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as file:
        dumped = json.load(file)
    return Spelling(dumped) if "dump" in (dumped.get("source") or {}) else None


def refused_calls(path=REFUSED_LIST):
    """The functions Wax refuses to call, as the file its runtime reads lists them: {path as it is compared: bytes}."""
    if not os.path.isfile(path):
        return {}
    with open(path, encoding="utf-8") as file:
        listed = read_lua_data(file.read(), path)
    out = {}
    for name, size in (listed.items() if isinstance(listed, dict) else ()):
        key = same_path(str(name))
        out[key] = max(out.get(key, 0), size)
    return out


class LuaTypes:
    """Editor types for index records. `chosen` limits the names that may be used; `spell_delegates` shows their parameters."""

    def __init__(self, game, names, chosen=None, root="WaxInstance", spell_delegates=False):
        self.game, self.names, self.chosen, self.root = game, names, chosen, root
        self.spell_delegates = spell_delegates

    def known(self, path):
        return path in self.names.of and (self.chosen is None or path in self.chosen)

    def object(self, path):
        for candidate in [path] + self.game.ancestors(path):
            if candidate in self.game.classes and self.known(candidate):
                return self.names.of[candidate]
        return self.root

    def of(self, described):
        kind = described["type"]
        if kind in INTEGER_TYPES:
            enum = described.get("enum")
            return self.names.of[enum] if enum and self.known(enum) else "integer"
        if kind in ("Float", "Double"):
            return "number"
        if kind == "Bool":
            return "boolean"
        if kind in ("Str", "Name", "Text"):
            return "string"
        if kind in OBJECT_TYPES:
            return self.object(described.get("ref", OBJECT))
        if kind in CLASS_TYPES:
            return self.object(CLASS)
        if kind == "Struct":
            return self.names.of[described["ref"]] if self.known(described.get("ref")) else "table"
        if kind == "Enum":
            return self.names.of[described["ref"]] if self.known(described.get("ref")) else "integer"
        if kind in ("Array", "Set"):
            return (self.of(described["inner"]) if "inner" in described else "any") + "[]"
        if kind == "Map":
            sides = [self.of(described[s]) if s in described else "any" for s in ("key", "value")]
            return f"table<{sides[0]}, {sides[1]}>"
        if kind in DELEGATE_TYPES:
            signature = self.game.delegates.get(described.get("ref")) if self.spell_delegates else None
            if signature:
                return "delegate(" + ", ".join(f"{n}: {t}" for n, t in self.parameters(signature)) + ")"
            return DELEGATE
        return "any"

    def parameters(self, function, checked=False):
        """(name, type) per parameter. For the checker an object may be nil and a struct may be any table, as Wax accepts both."""
        out, seen = [], set()
        for item in function["params"]:
            name = identifier(item["name"])
            while name in seen or name == "self":
                name += "_"
            seen.add(name)
            text = self.of(item)
            if checked and (item["type"] in OBJECT_TYPES or item["type"] in CLASS_TYPES):
                text += "?"
            elif checked and item["type"] == "Struct" and text != "table":
                text += "|{}"
            out.append((name, text))
        return out

    def result(self, function):
        return self.of(function["returns"]) if "returns" in function else None


def instance_api(folder):
    """The member names wax\\types gives every Instance. A game class does not declare those again."""
    return WaxApi(folder).instance_members()


def also_extends(game, names, api, chosen=None):
    """ALSO_EXTENDS as it can be written: ({game class: [Wax classes]}, [(game class, Wax class, why it is not written)]).

    A Wax class that another one of the same game class is built on is left out: it is reached through that one.
    """
    game_names = {name for path, name in names.of.items() if path in game.classes}
    written, unwritten = {}, []
    for path, listed in ALSO_EXTENDS.items():
        usable = []
        for name in listed:
            if path not in game.classes:
                why = "the index has no such class"
            elif chosen is not None and path not in chosen:
                why = "the class is not among the written ones"
            elif name not in api.classes:
                why = "wax\\types declares no such class"
            elif any(parent in game_names for above in api.above(name) for parent in api.classes[above]["parents"]):
                why = "it is built on a game class itself"
            else:
                usable.append(name)
                continue
            unwritten.append((path, name, why))
        usable = [name for name in usable if not any(name != other and name in api.above(other) for other in usable)]
        if usable:
            written[path] = usable
    return written, unwritten


class Reserved:
    """The member names Wax itself answers on an Instance of each game class, so that class does not declare them:
    what every Instance has, and what Wax's definitions add to the class or to a class above it, under the game
    class's own name or in a Wax class it also extends (also, from also_extends)."""

    def __init__(self, game, names, api, also=None):
        self.game, self.every = game, api.instance_members()
        self.own = {path: set(api.classes[name]["members"]) for name, path in names.added_to.items()}
        for path, listed in (also or {}).items():
            members = self.own.setdefault(path, set())
            for name in listed:
                for above in api.above(name):
                    members |= set(api.classes[above]["members"])
        self.cache = {}

    def of(self, path):
        found = self.cache.get(path)
        if found is None:
            found = set(self.every)
            for owner in [path] + self.game.ancestors(path):
                found |= self.own.get(owner, set())
            self.cache[path] = found
        return found


def wax_clashes(game, names, api, also=None):
    """Where a Wax name stands in front of a reflected member of the game.

    A Wax class reaches game objects when it is WaxInstance (every class), has the name of a game class, is
    built on a game class, alone or through other Wax classes, or is one a game class also extends (also, from
    also_extends), with the Wax classes that one is built on. Each of its members is compared, without letter
    case, with the reflected members of that game class, of the classes above it and of every class built on
    it. Gives rows (file, Wax class, member, game class path, the game's member), the topmost game class only.
    """
    by_name = {name: path for path, name in names.of.items() if path in game.classes}
    built_on = game.descendants()
    reflected = {}

    def members(path):
        found = reflected.get(path)
        if found is None:
            record = game.classes[path]
            found = reflected[path] = {item["name"].lower(): item["name"]
                                       for key in ("properties", "functions") for item in record.get(key, ())}
        return found

    anchors = defaultdict(set)      # Wax class -> the game classes its members are answered on
    for name, entry in api.classes.items():
        targets = {by_name[parent] for parent in entry["parents"] if parent in by_name}
        if name in names.added_to:
            targets.add(names.added_to[name])
        for above in api.above(name) if targets else ():
            anchors[above] |= targets
    for path, listed in (also or {}).items():
        for name in listed:
            for above in api.above(name):
                anchors[above].add(path)
    rows = []
    for name in sorted(api.classes):
        entry = api.classes[name]
        if name == INSTANCE:
            scope = set(game.classes)
        else:
            scope = set()
            for target in anchors.get(name, ()):
                scope.add(target)
                scope.update(game.ancestors(target))
                scope.update(built_on.get(target, ()))
            scope &= set(game.classes)
        if not scope:
            continue
        for member, file in sorted(entry["members"].items()):
            low = member.lower()
            for path in sorted(scope):
                theirs = members(path).get(low)
                if theirs is None or any(low in members(above) for above in game.ancestors(path) if above in scope):
                    continue
                rows.append((file, name, member, path, theirs))
    return rows


def clash_accepted(row):
    _file, name, member, path, _theirs = row
    return member in ALWAYS_ACCEPTED or (name, member, path) in ACCEPTED_CLASHES


def declared_entry_points(folder):
    """The class wax\\types gives each member of `game`, as {member: type text}."""
    path = os.path.join(folder, "game.lua")
    if not os.path.isfile(path):
        return {}
    with open(path, encoding="utf-8") as file:
        text = file.read()
    block = re.search(r"^---@class WaxGame\b.*?(?=^[^-])", text, re.M | re.S)
    return dict(re.findall(r"^---@field (\w+) (\S+)", block.group(0), re.M)) if block else {}


def field_line(name, text, note=""):
    key = name if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name) else '["%s"]' % name.replace("\\", "\\\\").replace('"', '\\"')
    return f"---@field {key} {text}{' ' + note if note else ''}"


REFUSED_NOTE = "Wax refuses this call from Lua."


def call_note(function, listed=False):
    """What the editor says about calling a function. Empty when nothing stands in the way.

    A size is only named when it was worked out. A function that is only on the list Wax's runtime refuses by
    gets no figure: that list's numbers were measured with local variables, which do not count.
    """
    flags = function["flags"]
    if "unsized" in flags and "frame" in function:
        return f"Do not call from Lua: it needs at least {function['frame']} bytes and the call buffer holds {CALL_BUFFER}."
    if "unsized" in flags:
        return "Do not call from Lua: the size of its parameters is not known for this build of the game."
    if "oversized" in flags:
        return f"Do not call from Lua: it needs {function['frame']} bytes and the call buffer holds {CALL_BUFFER}."
    return REFUSED_NOTE if listed else ""


def class_text(record, own, types, reserved, everything, refused=None, first=()):
    """The definition of one class or struct. first are Wax classes the class extends before its own parent."""
    parent = record.get("parent")
    header = f"---@class {own}"
    if record["path"] in types.game.classes:
        header += " : " + ", ".join(list(first) + [types.object(parent) if parent else types.root])
    elif parent and types.known(parent):
        header += " : " + types.names.of[parent]
    lines = [header]
    properties, functions = visible_members(record, everything)
    for name in sorted(properties):
        if name not in reserved:
            lines.append(field_line(name, types.of(properties[name])))
    for name in sorted(functions):
        if name in reserved:
            continue
        function = functions[name]
        arguments = "".join(f", {n}: {t}" for n, t in types.parameters(function, checked=True))
        result = types.result(function)
        note = call_note(function, bool(refused) and same_path(f"{record['path']}:{name}") in refused)
        lines.append(field_line(name, f"fun(self: {own}{arguments})" + (f": {result}" if result else ""), note))
    return "\n".join(lines) + "\n"


def enum_text(record, own):
    names = defaultdict(list)
    values = record["values"]
    if values and values[-1][0].upper().endswith("_MAX"):
        values = values[:-1]
    for name, value in values:
        names[value].append(name)
    lines = [f"---@alias {own}"] + [f"---| {value} # {', '.join(names[value])}" for value in sorted(names)]
    return "\n".join(lines + ["---| integer"]) + "\n"


def segments_of(record):
    parts = record["package"].strip("/").split("/")
    return ["script", parts[-1]] if record["native"] else ["content"] + parts[:-1]


def split_files(entries, limit, spare=1):
    """Groups (segments, name, text) into files under `limit` bytes, by folder and then by the first letters of the name."""
    files, taken = {}, set()

    def emit(stem, group):
        while stem.lower() in taken:
            stem += "+"
        taken.add(stem.lower())
        files[stem] = sorted((e[1], e[2]) for e in group)

    def size(group):
        return sum(len(e[2].encode("utf-8")) + spare for e in group)

    def by_letters(stem, group, width):
        buckets = defaultdict(list)
        for entry in group:
            buckets[entry[1][:width].upper()].append(entry)
        for letters, bucket in sorted(buckets.items()):
            if size(bucket) <= limit or len(bucket) == 1 or all(len(e[1]) <= width for e in bucket):
                emit(f"{stem}-{identifier(letters)}", bucket)
            else:
                by_letters(stem, bucket, width + 1)

    def place(prefix, group):
        depth = len(prefix)
        stem = "/".join(prefix[:1]) + ("/" + ".".join(prefix[1:]) if depth > 1 else "")
        if depth > 1 and size(group) <= limit:
            emit(stem, group)
            return
        here = [e for e in group if len(e[0]) <= depth]
        below = defaultdict(list)
        for entry in group:
            if len(entry[0]) > depth:
                below[entry[0][depth]].append(entry)
        for key, bucket in sorted(below.items()):
            place(prefix + [key], bucket)
        if here and size(here) <= limit:
            emit(stem, here)
        elif here:
            by_letters(stem, here, 1)

    place([], list(entries))
    return files


def declared_class(game, chain):
    """Follows property reads from the engine object. Returns the class the last one is declared as, and its name."""
    path, via = ENTRY_START, None
    for name in chain:
        item = game.property(path, name)
        item = item.get("inner", item) if item else None
        if not item or item.get("ref") not in game.classes:
            return None, None
        path, via = item["ref"], f"{leaf(path)}.{name}"
    return path, via


def play_classes(game):
    """The game's player controller that declares a character of its own, and that character's class."""
    for owner in game.index["classes"]:
        if owner["package"] == GAME_MODULE and game.inherits(owner["path"], "/Script/Engine.PlayerController"):
            for item in owner["properties"]:
                target = game.classes.get(item.get("ref")) if item["type"] == "Object" else None
                if target and target["package"] == GAME_MODULE and game.inherits(target["path"], "/Script/Engine.Pawn"):
                    return owner, target
    return None, None


def a(name):
    return f"{'an' if name[:1] in 'AEIOU' else 'a'} {name}"


def entry_points(game, types):
    """What the index says each member of `game` is: (member, type text, why). wax\\types\\game.lua is checked against it."""
    module = [c for c in game.index["classes"] if c["package"] == GAME_MODULE]
    controller, character = play_classes(game)
    rows = []
    for member, chain, lifetime in ENTRY_POINTS:
        path, via = declared_class(game, chain)
        if not path:
            continue
        found = path
        note = f"{via} is declared as {leaf(path)}." if via else f"Wax finds it as {a(leaf(path))}."
        if lifetime == "process":
            live = [c for c in game.index["classes"] if c.get("instances") and game.inherits(c["path"], path)]
            named = (game.index["source"].get("process_classes") or {}).get(path)
            if len(live) == 1 and live[0]["instances"] == 1 and live[0]["path"] != path:
                found = live[0]["path"]
                note += f" The dump holds one, {a(live[0]['name'])}."
            elif not live and named in game.classes and game.inherits(named, path):
                found = named
                note += f" The game's config starts {a(leaf(named))}."
        else:
            tops = [c for c in module if c["path"] != path and game.inherits(c["path"], path)
                    and game.classes.get(c.get("parent"), {}).get("package") != GAME_MODULE]
            if len(tops) == 1:
                found = tops[0]["path"]
                note += f" The game's own classes for it derive from {tops[0]['name']}."
        if controller and member == "LocalPlayer" and game.inherits(controller["path"], path):
            found = controller["path"]
            note += f" {controller['name']} is the game's controller that has a character."
        if controller and member == "Character" and game.inherits(character["path"], path):
            found = character["path"]
            note += f" {controller['name']} declares its character as {character['name']}."
        rows.append((member, types.object(found) + ("?" if member in OPTIONAL_ENTRIES else ""), note))
    return rows


def same_named(game, chosen, names):
    """Written blueprint classes that share a name, without letter case, and are not settled in PLAIN_NAMES."""
    groups = defaultdict(list)
    for path in chosen:
        record = game.classes.get(path)
        if record and not record["native"]:
            groups[identifier(record["name"]).lower()].append(path)
    rows = []
    for _name, paths in sorted(groups.items()):
        if len(paths) > 1 and not any(path.lower() in PLAIN_NAMES for path in paths):
            plain = min(paths, key=lambda path: len(names.of[path]))
            rows.append((names.of[plain], plain, sorted(path for path in paths if path != plain)))
    return rows


def make_types(index, wax_types=WAX_TYPES, everything=False, limit=TYPES_FILE_LIMIT, spelling=None, refused=None):
    """Returns {relative path: text} and a summary. Every class extends its parent, and Object extends WaxInstance.

    spelling (dump_spelling) gives names as the running game spelled them; refused (refused_calls) is the list
    Wax's runtime refuses calls by, so that the editor says what the game will do.
    """
    game = Game(respelled(index, spelling))
    api = WaxApi(wax_types)
    names = names_for(game, api)
    chosen = choose(game, everything)
    also, unwritten = also_extends(game, names, api, chosen)
    reserved = Reserved(game, names, api, also)
    types = LuaTypes(game, names, chosen, INSTANCE)
    entries, counts, classes, libraries, noted = [], defaultdict(int), [], {}, []
    for path in sorted(chosen):
        record, own = game.record(path), names.of[path]
        kind = game.kind(path)
        counts[kind] += 1
        if kind == "enum":
            text = enum_text(record, own)
        else:
            text = class_text(record, own, types, reserved.of(path) if kind == "class" else (), everything, refused,
                              also.get(path, ()) if kind == "class" else ())
            counts["members"] += text.count("\n---@field ")
            counts["do_not_call"] += text.count(" Do not call from Lua:")
            counts["refused"] += text.count(" " + REFUSED_NOTE + "\n")
        if kind == "class":
            classes.append(own)
            if path != FUNCTION_LIBRARY and game.inherits(path, FUNCTION_LIBRARY):
                libraries[own] = default_object(path)
            if refused:
                _properties, functions = visible_members(record, everything)
                hidden = reserved.of(path)
                noted += [(own, name) for name in functions
                          if name not in hidden and same_path(f"{path}:{name}") in refused]
        entries.append((segments_of(record), own, text))
    header = f"---@meta _\n{GENERATED}\n\n"
    files = {stem + ".lua": header + "\n".join(text for _name, text in group)
             for stem, group in split_files(entries, limit - len(header)).items()}
    files["base.lua"] = "\n".join(["---@meta _", GENERATED, "",
                                   "---A delegate property, as the engine holds it. Assigning one from Lua is refused.",
                                   f"---@class {DELEGATE}", ""])
    lua = [text for text in files.values()]
    # The editor plugin reads this list: a class name that is not on it is treated as a plain Instance.
    files[CLASS_LIST] = "\n".join(sorted(classes)) + "\n"
    declared = declared_entry_points(wax_types)
    found = entry_points(game, types)
    differ = [(member, declared.get(member), text, note) for member, text, note in found if declared.get(member) != text]
    read = {row[0] for row in found}
    clashes = wax_clashes(game, names, api, also)
    summary = {"classes": counts["class"], "structs": counts["struct"], "enums": counts["enum"], "members": counts["members"],
               "files": len(files), "bytes": sum(len(t.encode("utf-8")) for t in files.values()),
               "largest": max(len(t.encode("utf-8")) for t in lua), "root": INSTANCE,
               "entry_points": found, "entry_points_differ": differ,
               # A member of `game` whose chain of properties the index does not hold was not compared at all.
               "entry_points_unread": [member for member, _chain, _lifetime in ENTRY_POINTS if member not in read],
               "libraries": libraries, "do_not_call": counts["do_not_call"], "refused": counts["refused"],
               "refused_written": noted, "respelled_by": spelling.written if spelling else None,
               "wax_adds_to": dict(sorted(names.added_to.items())),
               "also_extends": {names.of[path]: list(listed) for path, listed in sorted(also.items())},
               "also_extends_unwritten": unwritten,
               "wax_clashes": clashes, "wax_clashes_open": [row for row in clashes if not clash_accepted(row)],
               "same_named": same_named(game, chosen, names)}
    return files, summary


def default_object(path):
    """The path of the object the engine keeps for a class, which a function library's functions are called on."""
    package, name = path.rsplit(".", 1)
    return f"{package}.Default__{name}"


def libraries_text(libraries):
    """What game:Library reads: the name of each function library and where its object is."""
    lines = [GENERATED, "return {"]
    lines += [f'    {name} = "{libraries[name]}",' if re.fullmatch(r"[A-Za-z_]\w*", name) and name not in LUA_KEYWORDS
              else f'    ["{name}"] = "{libraries[name]}",' for name in sorted(libraries)]
    return "\n".join(lines + ["}", ""])


def write_tree(out, files, marker):
    """Writes the files and removes ones an earlier run left behind."""
    out = os.path.abspath(out)
    kept = {os.path.normcase(os.path.join(out, *name.split("/"))) for name in files}
    for folder, _dirs, names in os.walk(out, topdown=False):
        for name in names:
            path = os.path.join(folder, name)
            if os.path.normcase(path) in kept:
                continue
            with open(path, encoding="utf-8", errors="replace") as file:
                ours = marker in file.read(400)
            if ours:
                os.remove(path)
        if folder != out and not os.listdir(folder):
            os.rmdir(folder)
    for name, text in files.items():
        write_text(os.path.join(out, *name.split("/")), text)


def placeholder(item, game):
    """What to write for an argument in an example: a plain value where one exists, else the parameter's own name."""
    kind = item["type"]
    if kind in INTEGER_TYPES or kind == "Enum":
        values = game.enums.get(item.get("ref") or item.get("enum"), {}).get("values")
        return str(values[0][1]) if values else "1"
    if kind in ("Float", "Double"):
        return "1.0"
    if kind == "Bool":
        return "true"
    if kind in ("Str", "Name", "Text"):
        return '"text"'
    if kind == "Struct":
        fields = game.structs.get(item.get("ref"), {}).get("fields", [])
        simple = all(f["type"] in INTEGER_TYPES or f["type"] in ("Float", "Double", "Bool") for f in fields)
        if fields and len(fields) <= 4 and simple:
            return "{ " + ", ".join(f"{f['name']} = {'false' if f['type'] == 'Bool' else '0'}" for f in fields) + " }"
        return "{}"
    if kind in ("Array", "Set", "Map"):
        return "{}"
    name = identifier(item.get("name", "value"))
    lowered = name[:1].lower() + name[1:]
    return name if lowered in LUA_KEYWORDS else lowered


def quoted(name):
    return '"%s"' % name.replace("\\", "\\\\").replace('"', '\\"')


def property_example(name, reserved, receiver="obj"):
    if name in reserved or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name) or name in LUA_KEYWORDS:
        return f"print({receiver}:Get({quoted(name)}))" if receiver == "obj" else f"print({receiver}[{quoted(name)}])"
    return f"print({receiver}.{name})"


def function_example(function, game, reserved):
    arguments = [placeholder(item, game) for item in function["params"]]
    name = function["name"]
    if name in reserved or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name) or name in LUA_KEYWORDS:
        call = f"obj:Call({', '.join([quoted(name)] + arguments)})"
    else:
        call = f"obj:{name}({', '.join(arguments)})"
    return f"local result = {call}" if "returns" in function else call


def site_type(record, game, types, reserved, everything, refused=None):
    kind = game.kind(record["path"])
    entry = {"name": record["name"], "kind": kind, "from": record["path"]}
    if record.get("parent"):
        entry["parent"] = leaf(record["parent"])
    if kind == "enum":
        entry["values"] = record["values"]
        return entry
    if kind == "class":
        entry["origin"] = "native" if record["native"] else "blueprint"
    properties, functions = visible_members(record, everything)
    receiver, hidden = ("obj", reserved) if kind == "class" else ("value", ())
    entry["props"] = [[name, types.of(item), property_example(name, hidden, receiver)] for name, item in sorted(properties.items())]
    if kind == "class":
        entry["funcs"] = []
        for name, function in sorted(functions.items()):
            row = [name, [[n, t] for n, t in types.parameters(function)], types.result(function) or "",
                   function_example(function, game, reserved)]
            flags = [f for f in function["flags"] if f in ("static", "event", "latent", "oversized", "unsure")]
            # The page marks what cannot be called: also a function of unknown size and one Wax's runtime refuses.
            barred = "unsized" in function["flags"] or bool(refused) and same_path(f"{record['path']}:{name}") in refused
            if barred and "oversized" not in flags:
                flags.append("oversized")
            entry["funcs"].append(row + [flags] if flags else row)
    return entry


def make_site(index, wax_types=WAX_TYPES, everything=False, limit=SITE_CHUNK_LIMIT, spelling=None, refused=None, whole=False):
    """Returns {relative path: text} and the manifest. whole lists every type of the index and not only what a mod
    meets; everything does too, and adds the members a compiler made."""
    game = Game(respelled(index, spelling))
    api = WaxApi(wax_types)
    names = names_for(game, api)
    chosen = choose(game, everything or whole)
    reserved = Reserved(game, names, api, also_extends(game, names, api, chosen)[0])
    types = LuaTypes(game, names, None, "WaxInstance", spell_delegates=True)
    entries = []
    for path in sorted(chosen):
        record = game.record(path)
        hidden = reserved.of(path) if path in game.classes else ()
        entries.append((segments_of(record), record["name"], compact(site_type(record, game, types, hidden, everything, refused))))
    files, chunks, listed, members = {}, [], [], defaultdict(list)
    for number, (stem, group) in enumerate(sorted(split_files(entries, limit - 200, 2).items())):
        chunk = stem.replace("/", ".")
        text = '{"chunk":%s,"types":[\n%s\n]}\n' % (json.dumps(chunk), ",\n".join(row for _name, row in group))
        files[f"chunks/{chunk}.json"] = text
        chunks.append({"id": chunk, "file": f"chunks/{chunk}.json", "types": len(group), "bytes": len(text.encode("utf-8"))})
        for _name, row in group:
            entry = json.loads(row)
            listed.append([entry["name"], number, entry["kind"][0]])
            for item in entry.get("props", []) + entry.get("funcs", []):
                members[item[0]].append(len(listed) - 1)
    search = '{"chunks":%s,\n"types":%s}\n' % (compact([c["id"] for c in chunks]), compact(listed))
    member_names = '{"members":%s}\n' % compact(dict(sorted(members.items())))
    files["search.json"] = search
    files["members.json"] = member_names
    manifest = {
        "format": FORMAT, "source": index["source"],
        "scope": "everything" if everything else "every type" if whole else "what a mod meets",
        "counts": {"types": len(listed), "classes": sum(1 for t in listed if t[2] == "c"),
                   "structs": sum(1 for t in listed if t[2] == "s"), "enums": sum(1 for t in listed if t[2] == "e"),
                   "members": sum(len(v) for v in members.values()), "chunks": len(chunks)},
        "layout": {
            "type": "name, kind (class, struct, enum), from (full path), parent, origin (native or blueprint)",
            "props": ["name", "type", "example"],
            "funcs": ["name", "params as [name, type]", "returns (empty for none)", "example", "flags (left out when none)"],
            "values": ["name", "number"],
            "search.types": ["name", "index into search.chunks", "c, s or e"],
            "members.members": "member name -> indexes into search.types",
        },
        "search": {"file": "search.json", "bytes": len(search.encode("utf-8"))},
        "members": {"file": "members.json", "bytes": len(member_names.encode("utf-8"))},
        "chunks": chunks,
    }
    files["manifest.json"] = json.dumps(manifest, indent=1) + "\n"
    return files, manifest


def type_text(described):
    kind = described["type"]
    if kind == "Array":
        return f"Array<{type_text(described['inner']) if 'inner' in described else '?'}>"
    if kind == "Set":
        return f"Set<{type_text(described['inner']) if 'inner' in described else '?'}>"
    if kind == "Map":
        return "Map<%s, %s>" % tuple(type_text(described[s]) if s in described else "?" for s in ("key", "value"))
    target = described.get("ref") or described.get("enum")
    return f"{kind}<{leaf(target)}>" if target else kind


def signature_text(function):
    text = "(" + ", ".join(f"{p['name']}: {type_text(p)}" for p in function["params"]) + ")"
    return text + (": " + type_text(function["returns"]) if "returns" in function else "")


def pair_renames(removed, added, same_place):
    """Pairs a removed member with an added one of the same type when the names are alike or they sit in the same place."""
    pairs = []
    for old_name, old in list(removed.items()):
        best, why, best_score = None, None, 0.0
        for new_name, new in added.items():
            if old["text"] != new["text"]:
                continue
            score = difflib.SequenceMatcher(None, old_name.lower(), new_name.lower()).ratio()
            if old.get("at") is not None and old.get("at") == new.get("at"):
                score, reason = score + 1.0, same_place
            elif score >= 0.6:
                reason = "similar name"
            else:
                continue
            if score > best_score:
                best, why, best_score = new_name, reason, score
        if best:
            pairs.append({"old": old_name, "new": best, "type": old["text"], "why": why})
            del removed[old_name]
            del added[best]
    return pairs


def diff_members(old, new, same_place="same position"):
    out = {}
    removed = {n: old[n] for n in old if n not in new}
    added = {n: new[n] for n in new if n not in old}
    renamed = pair_renames(removed, added, same_place)
    changed = [{"name": n, "old": old[n]["text"], "new": new[n]["text"]} for n in old if n in new and old[n]["text"] != new[n]["text"]]
    if added:
        out["added"] = [{"name": n, "type": v["text"]} for n, v in added.items()]
    if removed:
        out["removed"] = [{"name": n, "type": v["text"]} for n, v in removed.items()]
    if renamed:
        out["renamed"] = renamed
    if changed:
        out["changed"] = changed
    return out


def member_tables(record, spell=str):
    """Members by name with their type as text. `spell` rewrites the text, to follow a class that was renamed."""
    tables = {}
    if "values" in record:
        tables["values"] = {name: {"text": str(value), "at": value} for name, value in record["values"]}
        return tables
    items = record.get("properties", record.get("fields", []))
    tables["properties"] = {p["name"]: {"text": spell(type_text(p)), "at": p.get("offset")} for p in items}
    if "functions" in record:
        tables["functions"] = {f["name"]: {"text": spell(signature_text(f)), "at": None} for f in record["functions"]}
    return tables


def diff_records(old, new, moved, spell):
    out = {}
    if moved.get(old.get("parent"), old.get("parent")) != new.get("parent"):
        out["parent"] = [old.get("parent"), new.get("parent")]
    before, after = member_tables(old, spell), member_tables(new)
    for group in before:
        found = diff_members(before[group], after.get(group, {}), "same value" if group == "values" else "same position")
        if found:
            out[group] = found
    return out


def alike(old, new):
    if old.get("native") != new.get("native") or old.get("parent") != new.get("parent"):
        return False
    if old["native"] and old["package"] != new["package"]:
        return False
    if difflib.SequenceMatcher(None, old["name"].lower(), new["name"].lower()).ratio() >= 0.75:
        return True
    a = {n for table in member_tables(old).values() for n in table}
    b = {n for table in member_tables(new).values() for n in table}
    return len(a) >= 3 and len(a & b) / len(a | b) >= 0.7


def diff_indexes(old, new):
    result = {"old": old["source"], "new": new["source"]}
    groups = ("classes", "structs", "enums")
    before = {group: {r["path"]: r for r in old[group]} for group in groups}
    after = {group: {r["path"]: r for r in new[group]} for group in groups}
    moved = {}
    for group in groups:
        removed = [p for p in before[group] if p not in after[group]]
        added = [p for p in after[group] if p not in before[group]]
        renamed = []
        for path in list(removed):
            match = next((p for p in added if alike(before[group][path], after[group][p])), None)
            if match:
                renamed.append([path, match])
                moved[path] = match
                removed.remove(path)
                added.remove(match)
        result[group] = {"added": sorted(added), "removed": sorted(removed), "renamed": sorted(renamed), "changed": {}}
    # A member that only mentions a renamed class has not changed.
    names = {leaf(a): leaf(b) for a, b in moved.items() if leaf(a) != leaf(b)}
    pattern = re.compile(r"<(%s)>" % "|".join(map(re.escape, names))) if names else None
    spell = (lambda text: pattern.sub(lambda m: f"<{names[m.group(1)]}>", text)) if pattern else str
    for group in groups:
        for path, record in before[group].items():
            target = moved.get(path, path)
            if target in after[group]:
                found = diff_records(record, after[group][target], moved, spell)
                if found:
                    result[group]["changed"][target] = found
    return result


def diff_lines(result, new):
    game = Game(new)
    word = {"classes": "class", "structs": "struct", "enums": "enum"}
    single = {"properties": "property", "functions": "function", "values": "value"}
    lines = []
    for side in ("old", "new"):
        source = result[side]
        origin = f"the model of build {source['model']}" if source.get("model") else source.get("dump", "?")
        lines.append(f"{side.capitalize()}: {origin} written {source.get('written', '?')}")
    for group in ("classes", "structs", "enums"):
        found = result[group]
        lines.append(f"{group.capitalize()}: {len(found['added'])} added, {len(found['removed'])} removed, "
                     f"{len(found['renamed'])} renamed, {len(found['changed'])} changed")
    for group in ("classes", "structs", "enums"):
        found = result[group]
        for path in found["added"]:
            parent = game.record(path).get("parent")
            lines.append(f"+ {word[group]} {path}" + (f" : {leaf(parent)}" if parent else ""))
        for path in found["removed"]:
            lines.append(f"- {word[group]} {path}")
        for before, after in found["renamed"]:
            lines.append(f"> {word[group]} {before} -> {after}")
        for path, change in sorted(found["changed"].items()):
            lines.append(f"~ {word[group]} {path}")
            if "parent" in change:
                lines.append(f"    ~ parent {leaf(change['parent'][0] or 'none')} -> {leaf(change['parent'][1] or 'none')}")
            for kind in ("properties", "functions", "values"):
                part = change.get(kind, {})
                join = " = " if kind == "values" else "" if kind == "functions" else ": "
                for item in part.get("added", []):
                    lines.append(f"    + {single[kind]} {item['name']}{join}{item['type']}")
                for item in part.get("removed", []):
                    lines.append(f"    - {single[kind]} {item['name']}{join}{item['type']}")
                for item in part.get("renamed", []):
                    lines.append(f"    > {single[kind]} {item['old']} -> {item['new']}{join}{item['type']} ({item['why']})")
                for item in part.get("changed", []):
                    lines.append(f"    ~ {single[kind]} {item['name']}{join}{item['old']} -> {item['new']}")
    dumped = [side for side in ("old", "new") if not result[side].get("model")]
    if dumped and any(not path.startswith("/Script/") for path in result["classes"]["added"] + result["classes"]["removed"]):
        lines.append("A blueprint class is only in a dump while it is loaded, so one listed here may just not have been loaded.")
    return lines


def find(index, text, limit):
    game = Game(index)
    names = Names(game, declared_names(WAX_TYPES))
    types = LuaTypes(game, names, None, "WaxInstance")
    wanted = text.lower()
    rows = []

    def rank(name):
        low = name.lower()
        return 0 if low == wanted else 1 if low.startswith(wanted) else 2

    for group, word in (("classes", "class"), ("structs", "struct"), ("enums", "enum")):
        for record in index[group]:
            if wanted in record["name"].lower():
                parent = f" : {leaf(record['parent'])}" if record.get("parent") else ""
                rows.append((rank(record["name"]), 0, record["name"], f"{word} {record['name']}{parent}", record["path"]))
            for item in record.get("properties", record.get("fields", ())):
                if wanted in item["name"].lower():
                    rows.append((rank(item["name"]), 1, item["name"], f"{record['name']}.{item['name']}: {types.of(item)}", record["path"]))
            for function in record.get("functions", ()):
                if wanted in function["name"].lower():
                    arguments = ", ".join(f"{n}: {t}" for n, t in types.parameters(function))
                    result = types.result(function)
                    shown = f"{record['name']}:{function['name']}({arguments})" + (f": {result}" if result else "")
                    rows.append((rank(function["name"]), 2, function["name"], shown, record["path"]))
            for name, value in record.get("values", ()):
                if wanted in name.lower():
                    rows.append((rank(name), 3, name, f"{record['name']}.{name} = {value}", record["path"]))
    rows.sort()
    return rows[:limit], len(rows)


# What Wax uses of the game is a Lua data file: tables, strings, numbers, true and false.

LUA_TOKEN = re.compile(r"""--[^\n]*|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|-?\d+(?:\.\d+)?|[A-Za-z_]\w*|[{}=,;\[\]]|\s+|(.)""")
LUA_WORDS = {"true": True, "false": False, "nil": None}


def read_lua_data(text, origin="the Lua data"):
    """The value a Lua data file returns: a list for a table of items, a dict for one with keys."""
    tokens = []
    for match in LUA_TOKEN.finditer(text):
        token = match.group(0)
        if match.group(1):
            fail(f"{origin}, line {text.count(chr(10), 0, match.start()) + 1}: {token!r} is not data")
        if not token.isspace() and not token.startswith("--"):
            tokens.append(token)
    if tokens[:1] == ["return"]:
        tokens = tokens[1:]
    at = 0

    def value():
        nonlocal at
        token = tokens[at]
        at += 1
        if token == "{":
            keyed, listed = {}, []
            while tokens[at] != "}":
                if tokens[at] == "[":
                    at += 1
                    key = value()
                    if tokens[at:at + 2] != ["]", "="]:
                        fail(f"{origin}: a key in brackets needs ] and = after it")
                    at += 2
                    keyed[key] = value()
                elif tokens[at + 1] == "=":
                    key = tokens[at]
                    at += 2
                    keyed[key] = value()
                else:
                    listed.append(value())
                if tokens[at] in ",;":
                    at += 1
            at += 1
            if not keyed:
                return listed
            keyed.update((place + 1, item) for place, item in enumerate(listed))
            return keyed
        if token[0] in "\"'":
            return re.sub(r"\\(.)", lambda found: {"n": "\n", "t": "\t"}.get(found.group(1), found.group(1)), token[1:-1])
        if token in LUA_WORDS:
            return LUA_WORDS[token]
        try:
            return float(token) if "." in token else int(token)
        except ValueError:
            fail(f"{origin}: {token!r} is not data")

    try:
        result = value()
    except IndexError:
        fail(f"{origin} ends in the middle of a table")
    if at != len(tokens):
        fail(f"{origin}: there is text after the value it returns")
    return result


def read_needs(path):
    if not os.path.isfile(path):
        fail(f"No list of what Wax uses at {path}.")
    with open(path, encoding="utf-8") as file:
        parts = read_lua_data(file.read(), path)
    if not isinstance(parts, list) or not all(isinstance(part, dict) and part.get("id") and part.get("name") for part in parts):
        fail(f"{path} must return a list of parts, each with an id and a name.")
    return parts


class TableFiles:
    """The game's tables as Export-GameData wrote them: one JSON file per table, found by the table's name."""

    def __init__(self, folder):
        self.folder = folder
        self.paths, self.read = {}, {}
        for root, _folders, files in os.walk(folder):
            for name in files:
                if name.endswith(".json"):
                    self.paths[name[:-5]] = os.path.join(root, name)

    def get(self, name):
        if name not in self.read:
            data = None
            if name in self.paths:
                with open(self.paths[name], encoding="utf-8") as file:
                    data = json.load(file)
            self.read[name] = data if isinstance(data, dict) and "Rows" in data else None
        return self.read[name]

    def newest(self):
        return max((os.path.getmtime(path) for path in self.paths.values()), default=None)


def closest(name, candidates):
    """The existing name most like one that is gone, or None."""
    candidates = [candidate for candidate in candidates if candidate != name]
    for candidate in candidates:
        if same_name(candidate, name):
            return candidate
    near = difflib.get_close_matches(name, candidates, 1, 0.6)
    return near[0] if near else None


def members_of(game, path, key):
    """The names of one kind (properties, functions or fields) a class or struct has, with those of its parents."""
    names = []
    for owner in [path] + game.ancestors(path):
        names.extend(item["name"] for item in (game.record(owner) or {}).get(key, ()))
    return names


def in_values(values, parts):
    """True when the path leads somewhere in these values, False when it stops at one that is filled in, None when nothing is."""
    for part in parts:
        found, asked = [], False
        for value in values:
            for item in value if isinstance(value, list) else (value,):
                if isinstance(item, dict):
                    asked = True
                    key = folded(part, item, True)
                    if key in item:
                        found.append(item[key])
        if not found:
            return False if asked else None
        values = found
    return True


def in_struct(game, struct, parts):
    """The same for a struct of the index. With False come the closest name and why the path stops."""
    plain = None
    for part in parts:
        if plain:
            return False, None, f"{plain} has no fields"
        if struct not in game.structs:
            return None, None, None
        names = members_of(game, struct, "fields")
        part = folded(part, names, game.fold)
        if part not in names:
            return False, closest(part, names), "not in " + leaf(struct)
        field = next(item for owner in [struct] + game.ancestors(struct) for item in game.structs.get(owner, {}).get("fields", ())
                     if item["name"] == part)
        described = field.get("inner", field) if field["type"] == "Array" else field
        struct, plain = described.get("ref"), None if described["type"] == "Struct" else part
    return True, None, None


def check_field(game, row_struct, values, defaults, path):
    """fine, missing or unknown for one field path of a table, and the closest name when it is missing."""
    parts = path.split(".")
    known, hint, why = in_struct(game, row_struct, parts)
    if known is False:
        return "missing", hint, why
    if isinstance(defaults, dict) and defaults and folded(parts[0], defaults, True) not in defaults:
        return "missing", closest(parts[0], defaults), "not among the table's fields"
    if known or in_values(values, parts):
        return "fine", None, None
    return "unknown", None, "no row fills it in and the index does not hold the row's struct"


def check_part(part, game, tables):
    missing, unknown, checked = [], [], 0

    def gone(kind, name, hint=None, note=None):
        missing.append({"kind": kind, "name": name, "hint": hint, "note": note})

    def listed(key):
        return part.get(key) or []

    for entry in listed("classes") + listed("structs"):
        is_class = "class" in entry
        group = game.classes if is_class else game.structs
        path = folded(entry["class"] if is_class else entry["struct"], group, game.fold)
        wanted = [("property", "properties", name) for name in entry.get("properties") or []]
        wanted += [("function", "functions", name) for name in entry.get("functions") or []]
        wanted += [("field", "fields", name) for name in entry.get("fields") or []]
        checked += 1 + len(wanted)
        if path not in group:
            same = [other for other in group if leaf(other) == leaf(path)]
            if same:
                gone("class" if is_class else "struct", path, same[0], "it is at another path")
            elif path.startswith("/Script/") or game.index["source"].get("model"):
                # A model holds every class the game ships, so one it lacks is gone, blueprint or not.
                near = closest(leaf(path), [leaf(other) for other in group if package_of(other) == package_of(path)])
                near = near or closest(leaf(path), [leaf(other) for other in group])
                gone("class" if is_class else "struct", path, near and next(other for other in group if leaf(other) == near))
            else:
                also = f". Its members ({len(wanted)}) were not checked either" if wanted else ""
                unknown.append({"kind": "class" if is_class else "struct", "name": path,
                                "why": "not in this dump (a blueprint is only in it while it is loaded)" + also})
            continue
        for kind, key, name in wanted:
            names = members_of(game, path, key)
            if folded(name, names, game.fold) in names:
                continue
            other = {"properties": "functions", "functions": "properties"}.get(key)
            if other and folded(name, members_of(game, path, other), game.fold) in members_of(game, path, other):
                gone(kind, f"{path}:{name}", None, "it is a function now" if other == "functions" else "it is a property now")
            else:
                everything = names + (members_of(game, path, other) if other else [])
                gone(kind, f"{path}:{name}", closest(name, everything))

    for entry in listed("enums"):
        path, values = folded(entry["enum"], game.enums, game.fold), entry.get("values") or {}
        checked += 1 + len(values)
        record = game.enums.get(path)
        if not record:
            near = closest(leaf(path), [leaf(other) for other in game.enums])
            gone("enum", path, near and next(other for other in game.enums if leaf(other) == near))
            continue
        now = dict(record["values"])
        for name, number in sorted(values.items(), key=lambda pair: pair[1]):
            name = folded(name, now, game.fold)
            if name not in now:
                by_number = [other for other, value in now.items() if value == number]
                gone("value", f"{path}:{name}", None if by_number else closest(name, now),
                     by_number and f"{by_number[0]} has its number, {number}" or None)
            elif now[name] != number:
                gone("value", f"{path}:{name}", None, f"it is {now[name]} now and Wax expects {number}")

    for entry in listed("tables"):
        name, fields, meta = entry["table"], entry.get("fields") or [], entry.get("meta") or []
        checked += 1 + len(fields) + len(meta)
        data = tables.get(name)
        if not data:
            gone("table", name, closest(name, tables.paths))
            continue
        rows = data.get("Rows") or []
        for path in fields:
            state, hint, note = check_field(game, data.get("RowStruct"), [data.get("Defaults") or {}] + rows, data.get("Defaults"), path)
            if state == "missing":
                gone("field", f"{name}:{path}", hint, note)
            elif state == "unknown":
                unknown.append({"kind": "field", "name": f"{name}:{path}", "why": note})
        for path in meta:
            state, hint, note = check_field(game, META_STRUCT, [row["Metadata"] for row in rows if "Metadata" in row], None, path)
            if state == "missing":
                gone("field", f"{name} (its meta table):{path}", hint, note)
            elif state == "unknown":
                unknown.append({"kind": "field", "name": f"{name} (its meta table):{path}", "why": note})

    return {"id": part["id"], "name": part["name"], "checked": checked, "missing": missing, "unknown": unknown}


def check_needs(parts, index, tables):
    """Every name each part of Wax uses, looked up in the index and in the tables. One result per part."""
    game = Game(index)
    return [check_part(part, game, tables) for part in parts]


def needs_lines(results):
    lines = []
    for result in results:
        missing, unknown = result["missing"], result["unknown"]
        if missing:
            head = f"{len(missing)} of {result['checked']} names are gone" if len(missing) > 1 else f"1 of {result['checked']} names is gone"
        else:
            head = f"fine, {result['checked']} name{'' if result['checked'] == 1 else 's'}"
        if unknown:
            head += f", {len(unknown)} could not be checked"
        lines.append(f"{result['name']} ({result['id']}): {head}")
        for item in missing:
            more = [text for text in (item["note"], item["hint"] and f"closest: {item['hint']}") if text]
            lines.append(f"    - {item['kind']} {item['name']}" + (f"  ({', '.join(more)})" if more else ""))
        for item in unknown:
            lines.append(f"    ? {item['kind']} {item['name']}: {item['why']}")
    broken = [result["name"] for result in results if result["missing"]]
    names = sum(result["checked"] for result in results)
    if broken:
        lines.append(f"{len(broken)} of {len(results)} parts use names the game no longer has: {', '.join(broken)}.")
    else:
        lines.append(f"All {len(results)} parts are fine ({names} names).")
    return lines


def command_needs(args):
    index = load_index(args.index)
    tables = TableFiles(args.tables)
    if not tables.paths:
        fail(f"No tables in {args.tables}. Run: scripts\\Export-GameData.ps1")
    results = check_needs(read_needs(args.needs), index, tables)
    if args.json:
        print(json.dumps(results, indent=1))
    else:
        source = index["source"]
        written, read = source.get("written"), tables.newest()
        origin = f"the model of build {source['model']}, made {written}" if source.get("model") else f"the dump of {written}"
        print(f"Classes from {origin}, tables as read on {time.strftime('%Y-%m-%d %H:%M', time.localtime(read))}.")
        try:
            dumped = time.mktime(time.strptime(written, "%Y-%m-%d %H:%M"))
        except (TypeError, ValueError):
            dumped = None
        if dumped and read - dumped > 86400:
            again = "Make the model again (scripts\\gamemodel)" if source.get("model") else "Take a new dump"
            print(f"The tables are newer than the {'model' if source.get('model') else 'dump'}, so classes are checked "
                  f"against an older build of the game. {again}, then run build.")
        print("\n".join(needs_lines(results)))
    if any(result["missing"] for result in results):
        sys.exit(1)


def model_index(path=None):
    """The index made from the model of the game: (index, the model's file, what in the model needs a look).

    None when no model is there.
    """
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        from gamemodel import model as game_model, write as model_writers
    except ImportError:
        # A copy of the scripts without scripts\gamemodel still reads a dump.
        if path:
            fail("scripts\\gamemodel is not here, so a model cannot be read.")
        return None
    finally:
        sys.path.pop(0)
    path = path or game_model.find()
    if not path:
        return None
    try:
        model = game_model.load(path)
        return model_writers.index(model), path, game_model.unclean(model)
    except (game_model.ModelError, OSError, ValueError) as problem:
        fail(str(problem))


def command_build(args):
    started = time.perf_counter()
    made = None if args.dump else model_index(args.model)
    if made:
        index = made[0]
        print(f"From the model of build {index['source']['model']} ({made[1]}).")
    else:
        if not args.dump:
            print("No model of the installed build (python scripts\\gamemodel\\model.py), so the object dump is read. "
                  "It only holds the blueprint classes that were loaded when it was taken.")
        index = build_index(args.dump or DUMP, args.ue4ss_types)
    unclean = made[2] if made else []
    for line in unclean:
        print(f"CHECK the model: {line}")
    out = os.path.join(args.out, "index.json")
    if made and os.path.isfile(out):
        with open(out, encoding="utf-8") as file:
            from_dump = '"dump":' in file.read(300)
        if from_dump:
            # The dump's index is the one record of how the running game spelled names; it is kept beside the new one.
            os.replace(out, os.path.join(args.out, DUMP_INDEX))
            print(f"The index made from the object dump is kept as {DUMP_INDEX}.")
    write_index(index, out)
    counts = index["counts"]
    print(f"{counts['classes']} classes ({counts['native_classes']} native, {counts['blueprint_classes']} blueprint), "
          f"{counts['structs']} structs, {counts['enums']} enums")
    print(f"{counts['properties']} properties, {counts['struct_fields']} struct fields, {counts['functions']} functions, "
          f"{counts['parameters']} parameters")
    if not made and not index["source"]["ue4ss_types"]:
        print("No types folder beside the dump: byte enums and set elements stay unknown, and blueprint parameters are a best guess.")
    print(f"{out} ({os.path.getsize(out) / 1e6:.1f} MB) in {time.perf_counter() - started:.1f} s")
    # Written, with something to look at: the same code model.py and write.py end with for such a model.
    return 2 if unclean else 0


def types_of(index_path=INDEX, wax_types=WAX_TYPES, everything=False, refused_list=REFUSED_LIST):
    """make_types for an index on disk, as the `types` command runs it: names spelled by the index made from an
    object dump when one is beside the index, and calls marked by the list Wax's runtime refuses them by."""
    return make_types(load_index(index_path), wax_types, everything, spelling=dump_spelling(index_path),
                      refused=refused_calls(refused_list))


def check_lines(summary):
    """What `types` found that a person has to look at, one line each."""
    lines = []
    for member, declared, found, note in summary["entry_points_differ"]:
        lines.append(f"wax\\types\\game.lua: game.{member} is declared {declared or 'nothing'}, the index says {found}. {note}")
    for member in summary["entry_points_unread"]:
        lines.append(f"wax\\types\\game.lua: game.{member} was not compared, the index does not hold the properties Wax "
                     f"reads to reach it.")
    for path, name, why in summary["also_extends_unwritten"]:
        lines.append(f"scripts\\gameindex.py: ALSO_EXTENDS gives {leaf(path)} what {name} lists, and that was not written: {why}.")
    for file, name, member, path, theirs in summary["wax_clashes"]:
        if member not in ALWAYS_ACCEPTED:
            lines.append(f"wax\\types\\{file}: {name}.{member} replaces the game's {leaf(path)}.{theirs} "
                         f"(reach the game's with :Call / :Get)")
    for name, plain, others in summary["same_named"]:
        lines.append(f"{len(others) + 1} blueprint classes are called {name}: {plain} keeps the name, by its path, over "
                     f"{', '.join(others)}. Say which one keeps it in PLAIN_NAMES of scripts\\gameindex.py.")
    return lines


def command_types(args):
    started = time.perf_counter()
    files, summary = types_of(args.index, args.wax_types, args.all, args.refused)
    write_tree(args.out, files, GENERATED_BY)
    if os.path.abspath(args.out) == os.path.abspath(TYPES_DIR):
        write_text(LIBRARY_LIST, libraries_text(summary["libraries"]))
        print(f"{len(summary['libraries'])} function libraries listed in {LIBRARY_LIST}")
    print(f"{summary['classes']} classes, {summary['structs']} structs, {summary['enums']} enums, {summary['members']} members")
    print(f"{summary['files']} files, {summary['bytes'] / 1e6:.1f} MB, largest {summary['largest'] / 1024:.0f} KB, in {args.out}")
    print(f"Classes without a parent extend {summary['root']}.")
    if summary["respelled_by"]:
        print(f"Names are spelled as the running game spelled them in the object dump of {summary['respelled_by']}.")
    print(f"{summary['do_not_call']} functions are marked as too large to call, {summary['refused']} more as refused by Wax's list.")
    if summary["wax_adds_to"]:
        print("Wax's own definitions add members to these game classes: " + ", ".join(summary["wax_adds_to"]) + ".")
    if summary["also_extends"]:
        print("These game classes also extend what Wax gives them: " + ", ".join(
            f"{name} ({', '.join(listed)})" for name, listed in summary["also_extends"].items()) + ".")
    for line in check_lines(summary):
        print(f"CHECK {line}")
    print(f"Done in {time.perf_counter() - started:.1f} s")


def command_site(args):
    started = time.perf_counter()
    files, manifest = make_site(load_index(args.index), args.wax_types, args.all, spelling=dump_spelling(args.index),
                                refused=refused_calls(args.refused), whole=not args.met)
    write_tree(args.out, files, '"chunk":')
    counts = manifest["counts"]
    sizes = [c["bytes"] for c in manifest["chunks"]]
    print(f"{counts['classes']} classes, {counts['structs']} structs, {counts['enums']} enums, {counts['members']} members "
          f"({manifest['scope']})")
    print(f"{counts['chunks']} chunks, {sum(sizes) / 1e6:.1f} MB, largest {max(sizes) / 1024:.0f} KB, in {args.out}")
    print(f"Search list: types {manifest['search']['bytes'] / 1024:.0f} KB, member names {manifest['members']['bytes'] / 1024:.0f} KB")
    print(f"Done in {time.perf_counter() - started:.1f} s")


def command_diff(args):
    old, new = load_index(args.old), load_index(args.new)
    result = diff_indexes(old, new)
    if args.json:
        print(json.dumps(result, indent=1))
    else:
        print("\n".join(diff_lines(result, new)))


def command_find(args):
    rows, total = find(load_index(args.index), args.text, args.limit)
    width = max((len(row[3]) for row in rows), default=0)
    for row in rows:
        print(f"{row[3]:<{min(width, 90)}}  {row[4]}")
    if total > len(rows):
        print(f"{total - len(rows)} more. Raise --limit to see them.")
    if not rows:
        print(f"Nothing named like {args.text}.")


def main(argv=None):
    # The first line of the docstring, so the two cannot say different things.
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)

    build = commands.add_parser("build", help="write index.json from the model of the game, or from an object dump")
    build.add_argument("--model", default=None, metavar="FILE",
                       help="the model to read (default: build\\game-model\\<id of the installed build>\\model.json)")
    build.add_argument("--dump", default=None,
                       help="read a UE4SS object dump instead (without a model: game-data\\ue4ss\\ObjectDump.txt)")
    build.add_argument("--out", default=INDEX_DIR, help="folder for index.json (default: build\\game-index)")
    build.add_argument("--ue4ss-types", default=None, metavar="DIR",
                       help="the types folder UE4SS wrote (default: the one beside the dump; give an empty value to ignore it)")
    build.set_defaults(run=command_build)

    types = commands.add_parser("types", help="write editor definitions for game objects")
    types.add_argument("--index", default=INDEX, help="index.json to read (default: build\\game-index\\index.json)")
    types.add_argument("--out", default=TYPES_DIR, help="folder to write (default: wax\\types\\icarus)")
    types.add_argument("--wax-types", default=WAX_TYPES, help="Wax's own definitions (default: wax\\types)")
    types.add_argument("--all", action="store_true", help="every class in the index, with the members a compiler added")
    types.add_argument("--refused", default=REFUSED_LIST, metavar="FILE", help="the list of functions Wax refuses to call "
                       "(default: wax\\runtime\\data\\oversized_functions.lua)")
    types.set_defaults(run=command_types)

    site = commands.add_parser("site", help="write the data files of the game browser page")
    site.add_argument("--index", default=INDEX, help="index.json to read (default: build\\game-index\\index.json)")
    site.add_argument("--out", default=SITE_DIR, help="folder to write (default: build\\game-index\\site)")
    site.add_argument("--wax-types", default=WAX_TYPES, help="Wax's own definitions (default: wax\\types)")
    site.add_argument("--all", action="store_true", help="also the members a compiler added")
    site.add_argument("--met", action="store_true", help="only the types a mod meets, as the editor's definitions have them "
                      "(default: every class, struct and enum of the index)")
    site.add_argument("--refused", default=REFUSED_LIST, metavar="FILE", help="the list of functions Wax refuses to call "
                      "(default: wax\\runtime\\data\\oversized_functions.lua)")
    site.set_defaults(run=command_site)

    diff = commands.add_parser("diff", help="what changed between two index.json files")
    diff.add_argument("old", help="index.json from before the update")
    diff.add_argument("new", help="index.json from after it")
    diff.add_argument("--json", action="store_true", help="print JSON")
    diff.set_defaults(run=command_diff)

    search = commands.add_parser("find", help="search classes and members by name")
    search.add_argument("text", help="part of a name, in any letter case")
    search.add_argument("--index", default=INDEX, help="index.json to read (default: build\\game-index\\index.json)")
    search.add_argument("--limit", type=int, default=40, help="how many matches to print (default: 40)")
    search.set_defaults(run=command_find)

    needs = commands.add_parser("needs", help="check the names Wax uses against the index and the tables")
    needs.add_argument("--index", default=INDEX, help="index.json to read (default: build\\game-index\\index.json)")
    needs.add_argument("--needs", default=NEEDS, help="the list to check (default: wax\\runtime\\data\\needs.lua)")
    needs.add_argument("--tables", default=TABLES_DIR, help="the game's tables as JSON (default: game-data\\data)")
    needs.add_argument("--json", action="store_true", help="print JSON")
    needs.set_defaults(run=command_needs)

    args = parser.parse_args(argv)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main())
