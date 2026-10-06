---@meta _

---One row of a data table as plain Lua values, shaped like the game's own data files with every default filled in.
---`Name` is the row's name. A struct is a table and an array is a list.
---A name, a string and a text are Lua strings. A reference to an asset is its path, or nil when it points at nothing (false inside a list).
---A row is shared by everyone who reads it, so never change one.
---@alias WaxDataRow table<string, any>

---A row handle: the two names many fields hold to point at a row of another table.
---@class WaxRowHandle
---@field RowName string The row's name. "None" when the handle points at nothing.
---@field DataTableName string The table's name with "D_" in front, such as "D_ItemsStatic".

---One field of a row, as the game declares it.
---@class WaxDataField
---@field Name string The field's name.
---@field Kind string What the field holds: "Bool", "Int", "Float", "Byte", "Name", "Str", "Text", "SoftObject", "Struct", "Array", "Enum", "Map" and so on.
---@field Struct string? The struct's name, for a struct and for an array of structs.
---@field Inner string? What an array holds, named the way Kind is.

---@class WaxDataLoadOptions
---@field fields? string[] The field paths to read. Every readable field when omitted.
---@field names? string[] The rows to read. Every row when omitted. A name the table lacks is skipped.
---@field budget? number How many milliseconds of a frame the read may use before the task pauses. 1 when omitted.

---One of the game's data tables, such as ProcessorRecipes (every recipe) or Itemable (every item's name, icon and weight).
---A field path is a field's name, with a dot for each step into a struct or an array: "RequiredMillijoules",
---"Requirement.RowName", "Inputs.Element.RowName". Naming a struct or an array of structs asks for everything inside it.
---A wrong path raises an error that suggests the right one.
---Rows are read once and kept. A row is one table for as long as it is kept, and asking for more fields later adds them to that same table.
---Row names are matched without regard to letter case.
---Enum fields are read only when their own path is named, and they read as numbers.
---Maps, sets, delegates, doubles and references to live objects are never read. Naming one raises an error that says what it is.
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
---With `fields` only those are read. Without it the row holds every readable field.
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
---(RequiredFeatureLevel) and whether the game has retired it (bIsDeprecated).
---@return WaxDataTable?
function DataTable:Meta() end

---The table's row count and address as text, such as "2215:0x1F3A2B40". It is checked against the game each time.
---Keep it beside anything you worked out from the table: a different stamp means the table is not the one you read.
---@return string
function DataTable:Stamp() end

---The game's data tables as plain Lua values: recipes, items, creatures, talents and the rest.
---Nothing is read until you ask, and what was read is kept, so asking twice costs nothing.
---Text is kept in the language the game was showing when it was read. After the player changes the language it shows
---in the new one only after Flush, or when the game starts again.
---@class WaxData
---@field Changed WaxSignal<fun(name: string?)> Fires when the game has made a table again and what was read from it was dropped. `name` is the table's name, or nil when everything was dropped. Flush fires it too, with no name.
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
---that keeps something worked out from rows can work it out again.
function Data:Flush() end
