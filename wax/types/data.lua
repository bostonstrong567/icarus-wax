---@meta _

---One row of a data table as plain Lua values, shaped like the game's own data files with every default filled in.
---`Name` is the row's name. A struct is a table and an array is a list.
---A name, a string and a text are Lua strings. A reference to an asset is its path, or nil when it points at nothing (false inside a list or a map).
---A map is a table from each key to its value, and a reference to a curve is a WaxDataCurve. Both are only there when their own path was named.
---A row is shared by everyone who reads it, so never change one. To change what the game holds, use Set, Change or Add.
---@alias WaxDataRow table<string, any>

---One key of a curve.
---@class WaxDataCurveKey
---@field Time number Where the key is. For a creature's growth curve that is a level.
---@field Value number The curve's value there.

---A curve of the game (a CurveFloat) as plain numbers, the way a field that refers to one is read.
---For a creature's health or damage a step is a level: `curve.Values[level - curve.First + 1]` is the value at that level.
---A curve with no keys has First 0, Last -1 and empty Values and Keys.
---@class WaxDataCurve
---@field First integer The first whole step at or after the curve's first key.
---@field Last integer The last whole step at or before the curve's last key. Below First when no whole step lies between the two.
---@field Values number[]? The curve's value at First, First + 1 and so on to Last. The game works each one out, so a curve that bends between its keys is right too. Nil when that would be more than 1,024 values.
---@field Keys WaxDataCurveKey[]? The curve's own keys, in order. They do not say how the curve bends between two of them. Nil when the curve has more than 256.

---A row handle: the two names many fields hold to point at a row of another table.
---@class WaxRowHandle
---@field RowName string The row's name. "None" when the handle points at nothing.
---@field DataTableName string The table's name with "D_" in front, such as "D_ItemsStatic".

---One field of a row, as the game declares it.
---@class WaxDataField
---@field Name string The field's name.
---@field Kind string What the field holds: "Bool", "Int", "Float", "Byte", "Name", "Str", "Text", "SoftObject", "Struct", "Array", "Enum", "Map", "Object" (a reference to a live object, such as a curve) and so on.
---@field Struct string? The struct's name, for a struct and for an array of structs.
---@field Inner string? What an array holds, named the way Kind is.

---@class WaxDataLoadOptions
---@field fields? string[] The field paths to read. When omitted, everything that is read without being named, which leaves out enums, maps and curves.
---@field names? string[] The rows to read. Every row when omitted. A name the table lacks is skipped.
---@field budget? number How many milliseconds of a frame the read may use before the task pauses. 1 when omitted.

---@class WaxDataAddOptions
---@field like string The row of the table that the new row is a copy of.

---One thing a mod changed in a table, as Changes lists it: a field of a row, or a row that was added.
---@class WaxDataChange
---@field Table string The table's name, such as "ProcessorRecipes".
---@field Row string The row's name.
---@field Field string? The field, spelled as the game spells it. Nil for a row that was added.
---@field Was any What the field held before any mod changed it. Nil for a row that was added.
---@field Now any What the field holds now. Nil for a row that was added, and for a stuck field that could not be read.
---@field By string The mod whose change is on top, or the mod that added the row. For a stuck field nobody changes any more, the mod that left it so.
---@field Others string[]? The other mods that changed the field, in the order they load. Nil for a row that was added.
---@field Stuck boolean? True while the game does not hold what the field should hold, because it did not take a put-back. Wax tries again after 1, 5 and 30 seconds and on every new map.
---@field Added boolean? True for a row that was added.
---@field Like string? The row an added row is a copy of.
---@field Off boolean? True for an added row that is switched off because its mod unloaded or reset it.

---A field that two mods changed in ways that do not both show, as Conflicts lists it.
---@class WaxDataConflict
---@field Table string The table's name.
---@field Row string The row's name.
---@field Field string The field.
---@field Used string The mod whose Set the field holds.
---@field Covered string[] The mods whose change of the field is hidden under it.

---One of the game's data tables, such as ProcessorRecipes (every recipe) or Itemable (every item's name, icon and weight).
---A field path is a field's name, with a dot for each step into a struct or an array: "RequiredMillijoules",
---"Requirement.RowName", "Inputs.Element.RowName". Naming a struct or an array of structs asks for everything inside it.
---A wrong path raises an error that suggests the right one.
---Rows are read once and kept. A row is one table for as long as it is kept, and asking for more fields later adds them to that same table.
---Row names and field names are matched without regard to letter case. The keys of a row are spelled as the game spells them.
---Enum fields are read only when their own path is named, and they read as numbers.
---A map field is read only when its own path is named ("ArmourStats", "Creatures.WorldStatInjection"), and it is read whole: a path
---cannot go on into a map. It is a table from each key to its value. A key is a string or a number: a name, a string, the number
---of an enum, a whole number or a float, an asset's path, the row name of a row handle, and the one name inside a row enum or a
---tag, so a stat map reads `{ ["BaseMaximumHealth_+"] = 100 }`. An entry whose key is a reference to no asset is left out.
---A value is what a field of that kind is anywhere in a row: a number, true or false, a string, a struct as a table (a row handle
---among them, as its two names) without the enums, maps and curves inside it, an asset's path, or the numbers of a curve.
---A value that refers to nothing is false, so its key is still there.
---A map is refused when its keys are references to live objects, or structs other than a row handle and a struct with a single
---name or number in it, and when its values are lists, maps, sets or live objects other than curves. What a map holds is learned
---from the first entry read, so the error that says which of these it is comes when a row that has an entry in that map is read,
---and at once from then on.
---A map with more than 4,096 entries is not read: its row is nil and the log says why.
---A field that refers to a CurveFloat is read only when its own path is named, as a WaxDataCurve, or nil when it refers to
---nothing. A curve that several rows refer to is asked of the game once, and each row gets its own copy of the numbers.
---A field that refers to any other live object, such as a texture, raises an error when a row where it is set is read.
---Sets, delegates, doubles, weak references and lists of live objects are never read. Naming one raises an error that says what it is.
---@class WaxDataTable
---@field Name string The table's name without the "D_" in front, such as "ProcessorRecipes".
---@field RowStruct string The name of the struct every row of the table is, such as "ProcessorRecipe".
---@field Raw any The UE4SS table itself, found again each time this is read. Nil while the game does not have it. Do not keep it past the frame.
local DataTable = {}

---How many rows the table has.
---@return integer
function DataTable:Count() end

---The name of every row, spelled and ordered as the game has them.
---@return string[]
function DataTable:GetNames() end

---True when the table has a row of this name.
---@param name string
---@return boolean
function DataTable:Has(name) end

---One row, or nil when the table has no row of this name or the row could not be read.
---With `fields` only those are read. Without it the row holds everything that is read without being named, which leaves out enums, maps and curves.
---To read a map or a curve, name it: `game.Data:Table("AIGrowth"):Row("Deer", { "Base", "Health" })`.
---A struct or a list that was read with a map or a curve inside it is refused by Set until that key is taken out again.
---@param name string
---@param fields? string[]
---@return WaxDataRow?
function DataTable:Row(name, fields) end

---Reads many rows without holding the game up, and returns them by name. It only works inside a task.
---The task pauses whenever it has used its budget for the frame, and goes on in the next one.
---Rows that already hold the fields are not read again, so a second Load costs nothing and a Load that was stopped goes on where it left off.
---@param options? WaxDataLoadOptions
---@return table<string, WaxDataRow> rows
function DataTable:Load(options) end

---How far a Load of these fields has come.
---@param fields? string[]
---@return integer done The rows that already hold these fields.
---@return integer total The rows the table has.
---@return integer failed The rows that could not be read.
function DataTable:Loaded(fields) end

---The fields of a row as the game declares them. With `path`, the fields of the struct at that field path.
---@param path? string
---@return WaxDataField[]
function DataTable:Fields(path) end

---The table's meta table, or nil when it has none. Its rows have the same names and say which expansion a row belongs to
---(RequiredFeatureLevel) and whether the game has retired it (bIsDeprecated). A meta table can be read, not changed.
---@return WaxDataTable?
function DataTable:Meta() end

---The table's row count and address as text, such as "2215:0x1F3A2B40". It is checked against the game each time.
---Once a mod has changed the table, a third part counts what was written to it: "2215:0x1F3A2B40:7". The count only goes up.
---Keep the stamp beside anything you worked out from the table: a different stamp means the table is not what you read.
---@return string
function DataTable:Stamp() end

---Gives one field of a row a new value in the game. It is written before Set returns, so whatever the game reads from the row next is the new value.
---In a game someone else hosts, this changes the tables on this PC only: the host works from its own tables and decides what
---really happens. The player is told so once for each mod, in each game they join. `game.IsHost` says which it is.
---`field` is a whole field of the row, such as "Inputs", not a path into one.
---The value is whole: a struct with each of its fields, a list with each of its entries, as Change hands it to its function.
---Row gives the same, except that it leaves an enum inside a struct out until that enum's own path is named
---(`Row(name, { "SessionRequirement.DataTableName" })`). Set needs it and raises "SessionRequirement lacks DataTableName" without it.
---Two things may be left out of a struct: a typed row handle's DataTableName, which is filled in from the kind of handle, and text and
---references to assets, which stay as they are.
---A typed row handle only takes its own table: an ItemsStaticRowHandle names a row of ItemsStatic and nothing else, apart from
---the table and row the field holds already. A table name is taken with or without "D_", in any letter case, and written as
---the game lists it.
---An enum takes its number. Once Wax has read a value of that field in this session (for a list: from a row where the list has
---an entry), the number has to be one the enum has or the one the field holds, and the enum's name as the game spells it is taken
---too. Until then a name raises an error that asks for the number.
---Everything is checked before anything is written: the row, the field, the kind of every value, and that a row handle or a
---row enum names a row its table has (a row the field already names may stay, as some of the game's own rows name rows that are
---not there). What is wrong raises an error that names the place, such as "Inputs[2] lacks Count".
---After the write the field is read again. If the game did not take the value, the old one is put back and an error says what differed.
---The change belongs to the mod that makes it and is put back when the mod unloads. A mod that makes the same change again in
---the frame it reloads, or within 2 seconds of it, writes nothing. A change it no longer makes is put back when those 2 seconds
---are over. After a reload the row may still hold the mod's own earlier value, so a new value worked out from what the row
---holds belongs in Change. When two mods set one field, the mod that loads later is used, and Conflicts lists the field.
---With a table of fields in place of the field name, every value is checked before any is written. Two keys that mean the same
---field, such as Count and count, are an error.
---This version does not change text, references to assets, maps, sets, doubles or references to live objects.
---A list whose entries only the game can make (they hold one of those, a row enum or a multi row handle) keeps its length: its
---entries can be changed where they are, not added or removed. A kind of change that this version has switched off raises an error
---that says so. That can be a list that would get longer or shorter while it has more than 4 entries, while it is inside another
---value, or while its entries are strings or can hold strings or lists of their own. It can also be a row handle pointed at
---another table than the one it names now.
---@param row string
---@param field string
---@param value any
---@overload fun(self: WaxDataTable, row: string, fields: table<string, any>)
function DataTable:Set(row, field, value) end

---Changes one field of a row from the value it has. `fn` gets a copy of the whole value, enums included as numbers, and returns
---the new one. For a struct or a list it may change the copy and return nothing. The result is checked and written as Set does it.
---Wax keeps the function and runs it again when a mod that loads earlier changes the field or unloads, so it should depend on
---nothing but the value it is given. It has to return at once: a function that waits (`task.wait`, `Signal:Wait`, `Table:Load`)
---is an error. Changes of two mods to one field both hold: each builds on the other's, in the order the mods load.
---Change adds to what this mod changed in the field before. Set starts over.
---@param row string
---@param field string
---@param fn fun(value: any): any
function DataTable:Change(row, field, fn) end

---Adds a row: a copy of the row `options.like` names, as that row is now, with `values` written over it as Set would. Returns the row's name.
---The name is letters, digits and underscores and begins with the mod's id and an underscore, such as "MyMod_Quick_Axe".
---A character of the id that is none of those counts as an underscore. The game's own index of the table is renewed, so the game knows the row at once.
---The row belongs to the mod that added it, and Add again for the same row uses the row that is there.
---When the mod unloads, what it wrote into the row is put back and the row stays in the table, because a row is not taken out while
---the game runs. A recipe is switched off then: bForceDisableRecipe is set and it is on no bench, which takes it off the game's
---lists. The game still makes it when something asks for it by name. A row of another table is left as it is.
---A row that could not be switched off like that in this version is refused as the row to start from, with an error that says why.
---A row of the game is never replaced or removed.
---In a game someone else hosts, Add raises an error, because the host's game would not have the row.
---While adding rows is switched off in a version of Wax, Add raises an error that says so.
---@param name string
---@param values? table<string, any> Fields of the new row, each as Set takes it.
---@param options WaxDataAddOptions
---@return string name
function DataTable:Add(name, values, options) end

---Takes this mod's changes back: of one field, of one row when no field is given, of the whole table when no row is given.
---A row this mod added is switched off as when the mod unloads. What other mods changed stays.
---If the game does not take a field back, Reset raises an error and that change stands as before, so Reset can be called again.
---@param row? string
---@param field? string
---@return integer count How many changes were taken back.
function DataTable:Reset(row, field) end

---What mods changed in this table and still stands, sorted by row and field.
---@return WaxDataChange[]
function DataTable:Changes() end

---The fields of this table where one mod's Set hides another mod's different result. Two mods that set the same value are in
---no conflict, and neither is a Change on top of another mod's change.
---@return WaxDataConflict[]
function DataTable:Conflicts() end

---The game's data tables as plain Lua values: recipes, items, creatures, talents and the rest.
---Nothing is read until you ask, and what was read is kept, so asking twice costs nothing.
---Text is kept in the language the game was showing when it was read. After the player changes the language it shows
---in the new one only after Flush, or when the game starts again.
---@class WaxData
---@field Changed WaxSignal<fun(name: string?)> Fires when what was read from a table no longer holds: the game made the table again, or rows of it were written for a mod (then at the end of that frame, once for the table). While many fields are put back over several frames it fires at most four times a second, and once when the put-back is done. `name` is the table's name, or nil when everything was dropped. Flush fires it too, with no name.
---@field Patched WaxSignal<fun(table: string, row: string, field: string?)> Fires for each field of a row that was written, by a mod's change, by a Reset or because a mod unloaded: at the end of that frame, or together with Changed while many fields are put back over several frames. `field` is nil when the row itself was added, switched off or taken out.
local Data = {}

---A table by name, with or without the "D_" in front. Letter case does not matter.
---A wrong name raises an error that suggests the right one.
---@param name string
---@return WaxDataTable
function Data:Table(name) end

---The name of every table the game has, sorted.
---@return string[]
function Data:GetTables() end

---True when the game has a table of this name.
---@param name string
---@return boolean
function Data:Has(name) end

---The row a row handle points at, and the table it is in. Nil when the handle points at nothing or at a row the game does not have.
---A handle whose DataTableName was not read as a name raises an error. Read such a row with Table and Row.
---@param handle WaxRowHandle
---@param fields? string[]
---@return WaxDataRow? row The row, or nil.
---@return WaxDataTable? table The table the row is in.
function Data:Resolve(handle, fields) end

---Forgets everything that was read, so the next read asks the game again. Use it after the player changes the game's language.
---Rows handed out before stay as they are and are no longer filled in. Changed fires at the end of the frame, so every mod
---that keeps something worked out from rows can work it out again. What mods changed in the tables stays changed.
function Data:Flush() end

---What mods changed in every table and still stands, sorted by table, row and field.
---@return WaxDataChange[]
function Data:Changes() end

---Every field, in every table, where one mod's Set hides another mod's different result.
---@return WaxDataConflict[]
function Data:Conflicts() end
