---@meta _

---What every control has.
---@class WaxControl
---@field Changed WaxSignal Fires when the user changes the control's value.
local Control = {}

---Removes the control.
function Control:Destroy() end

---Shows or hides the control. A hidden control takes no room.
---@param shown boolean
function Control:SetVisible(shown) end

---Greys the control out and stops it reacting, or makes it usable again.
---@param enabled boolean
function Control:SetEnabled(enabled) end

---@class WaxLabelOptions: WaxOptions
---@field dim? boolean Uses the theme's secondary text colour.
---@field color? WaxColor
---@field size? number
---@field face? string Typeface of the "ui" family: "Book", "Medium", "Bold" ...
---@field family? WaxFontFamily "ui" (the game's own interface font) when omitted.

---@class WaxLabel: WaxControl
local Label = {}

---Replaces the text.
---@param value any
function Label:Set(value) end

---Changes the text colour.
---@param color WaxColor
function Label:SetColor(color) end

---@class WaxHeading: WaxControl
local Heading = {}

---Replaces the text.
---@param value any
function Heading:Set(value) end

---@class WaxButtonOptions: WaxOptions
---@field primary? boolean Draws the button in the accent colour.
---@field stretch? boolean A button with a caption is as wide as its container. False keeps it as wide as its caption. An icon-only button is small unless this is true.
---@field icon? string Icon name shown before the caption. The menu's Icons page lists the names.
---@field spin? boolean The icon turns round once on every click, to show that something has started.

---@class WaxButton: WaxControl
---@field Activated WaxSignal<fun()> Fires on each click, after on_click.
---@field Changed WaxSignal<fun()> The same signal as Activated.
local Button = {}

---Shows another icon on a button that was made with one.
---@param name string
function Button:SetIcon(name) end

---Turns the icon round once.
function Button:Spin() end

---@class WaxIconOptions: WaxOptions
---@field size? number Default 20.
---@field color? WaxColor The theme's text colour when omitted.

---@class WaxIcon: WaxControl
local Icon = {}

---Shows another icon.
---@param name string
function Icon:Set(name) end

---@class WaxToggle: WaxControl
---@field Changed WaxSignal<fun(on: boolean)> Fires when the user flips the switch.
local Toggle = {}

---True while the switch is on.
---@return boolean
function Toggle:Get() end

---Turns the switch on or off without firing Changed.
---@param on boolean
---@param instant? boolean True skips the sliding animation, for a switch that is being reused for another row.
function Toggle:Set(on, instant) end

---Changes the text beside the switch.
---@param text string
function Toggle:SetCaption(text) end

---A colour selector. It opens a panel with a shade box, a hue bar and the colour as text that can be typed, pasted or copied.
---@class WaxColorControl: WaxControl
---@field Changed WaxSignal<fun(color: string)> Fires with "#rrggbb" on every change, also while the mouse is held.
---@field Released WaxSignal<fun(color: string)> Fires once when the user lets go, or commits a typed colour. Use it for saving.
local ColorControl = {}

---The colour as "#rrggbb".
---@return string
function ColorControl:Get() end

---Sets the colour without firing Changed.
---@param color string "#rrggbb"
function ColorControl:Set(color) end

---A page or group title: large text, an optional line under it, and a rule.
---@class WaxTitle: WaxControl
local Title = {}

---Changes the title text.
---@param content any
function Title:Set(content) end

---Changes the line under the title (only if the title was made with one).
---@param description any
function Title:SetDescription(description) end

---@class WaxSliderOptions: WaxOptions
---@field min? number Default 0.
---@field max? number Default 1.
---@field value? number The starting value. `min` when omitted.
---@field step? number Values snap to this step, counted from `min`.
---@field format? string string.format pattern for the read-out. "%.2f" when omitted, or "%d" with a step of 1 or more.
---@field stacked? boolean True puts the caption above the track, false beside it. When omitted, the room available decides.
---@field live? boolean False reports the value once, when the mouse lets go, for changes too heavy to make while dragging. True when omitted.

---A slider. The number beside it can be clicked and typed into.
---@class WaxSlider: WaxControl
---@field Changed WaxSignal<fun(value: number)> Fires with each new value while the user drags (once, on letting go, with live = false), and when a number is typed.
---@field Released WaxSignal<fun(value: number)> Fires once when the user lets go, for changes too heavy to apply during the drag.
local Slider = {}

---The current value.
---@return number
function Slider:Get() end

---Moves the slider (snapped and kept within its range) without firing Changed.
---@param value number
function Slider:Set(value) end

---@class WaxInputOptions: WaxOptions
---@field text? string The starting text.
---@field hint? string Greyed text shown while the box is empty.
---@field stacked? boolean True puts the caption above the box, false beside it. When omitted, the room available decides.
---@field mono? boolean A fixed-width font, for code.

---@class WaxInput: WaxControl
---@field Changed WaxSignal<fun(text: string)> Fires when the text is committed (Enter, or the box losing focus).
---@field Entered WaxSignal<fun(text: string)> Fires only when Enter is pressed, even when the text is the same as last time (for a command line).
---@field Typed WaxSignal<fun(text: string)> Fires on every change to the text while typing.
local Input = {}

---The text in the box.
---@return string
function Input:Get() end

---Gives the box the keyboard, so the user can type without clicking it.
function Input:Focus() end

---True while the box has the keyboard.
---@return boolean
function Input:HasFocus() end

---Shows greyed text after what is typed, such as the rest of a suggested word. Only a box made with mono = true shows it.
---@param text string Empty to show nothing.
function Input:SetGhost(text) end

---Replaces the text without firing Changed.
---@param text any
function Input:Set(text) end

---A dropdown opens in place under its header. The chosen row is highlighted, and only one list is open at a time.
---@class WaxDropdown: WaxControl
---@field Changed WaxSignal<fun(choice: any)> Fires when the user picks a choice.
local Dropdown = {}

---The selected choice.
---@return any
function Dropdown:Get() end

---Selects a choice without firing Changed.
---@param choice any
function Dropdown:Set(choice) end

---@class WaxSectionOptions: WaxOptions
---@field open? boolean False starts the section collapsed.
---@field collapsible? boolean False makes a plain titled group that is always open.

---A collapsible card. It is a container for controls.
---@class WaxSection: WaxContainer
---@field control WaxControl The card itself, for Destroy, SetVisible and SetEnabled.
local Section = {}

---Expands or collapses the section.
---@param open boolean
function Section:SetOpen(open) end

---True while the section is expanded.
---@return boolean
function Section:IsOpen() end

---A container whose controls sit side by side.
---@class WaxRow: WaxContainer
---@field control WaxControl The row itself, for Destroy, SetVisible and SetEnabled.

---@class WaxProgressOptions: WaxOptions
---@field color? WaxColor|string|integer The accent colour when omitted. "#RRGGBB" works too.

---@class WaxProgress: WaxControl
local Progress = {}

---The current value, 0..1.
---@return number
function Progress:Get() end

---Moves the bar to a value of 0..1.
---@param value number
function Progress:Set(value) end

---Changes the colour of the filled part.
---@param color WaxColor
function Progress:SetColor(color) end

---@class WaxFieldOptions: WaxOptions
---@field mono? boolean Shows the value in the small fixed-width font, for numbers that keep changing.

---@class WaxField: WaxControl
local Field = {}

---Replaces the value.
---@param value any
function Field:Set(value) end

---Changes the colour of the value.
---@param color WaxColor
function Field:SetColor(color) end

---@class WaxKeybind: WaxControl
---@field Changed WaxSignal<fun(key: string)> Fires with the engine's name of the key the user pressed.
local Keybind = {}

---The key's engine name, or nil when none is set.
---@return string?
function Keybind:Get() end

---Sets the key without firing Changed.
---@param key string?
function Keybind:Set(key) end

---@class WaxConsoleOptions: WaxOptions
---@field height? number Default 220. On a page made with scroll = false it takes the space left when omitted.
---@field max? integer The most lines shown. Default 150.

---One console line: the text, then an optional colour.
---@alias WaxConsoleLine { [1]: any, [2]: WaxColor? }

---A log: coloured lines the user can select across (drag, Ctrl+A) and copy (Ctrl+C).
---@class WaxConsole: WaxControl
local Console = {}

---Everything being shown, as one text (for ui.Copy).
---@return string
function Console:GetText() end

---Shows these lines, or the last `max` of them.
---@param lines WaxConsoleLine[]
function Console:SetLines(lines) end

---Turns scrolling to the newest line on every SetLines on or off. It starts on.
---@param on boolean
function Console:SetFollow(on) end

---Something controls can be added to: a window, a page, a section, a row or an overlay.
---@class WaxContainer
local Container = {}

---Adds text that wraps to the container's width.
---@param content any
---@param options? WaxLabelOptions
---@return WaxLabel
function Container:Label(content, options) end

---Adds a bold title line.
---@param content any
---@return WaxHeading
function Container:Heading(content) end

---Adds a thin dividing line.
---@return WaxControl
function Container:Separator() end

---Adds an empty gap, as tall as the theme's spacing when no height is given.
---@param height? number
---@return WaxControl
function Container:Spacer(height) end

---Adds a button. on_click runs on each click. With an icon and no caption it is an icon button.
---@param caption? string
---@param on_click? fun()
---@param options? WaxButtonOptions
---@return WaxButton
function Container:Button(caption, on_click, options) end

---Adds an icon on its own, by name. The menu's Icons page lists the names.
---@param name string
---@param options? WaxIconOptions
---@return WaxIcon
function Container:Icon(name, options) end

---Adds a switch. on_change(on) runs when the user flips it.
---@param caption string
---@param initial? boolean
---@param on_change? fun(on: boolean)
---@return WaxToggle
function Container:Toggle(caption, initial, on_change) end

---Adds a slider with a read-out. on_change(value) runs while the user drags it.
---@param caption string
---@param options? WaxSliderOptions
---@param on_change? fun(value: number)
---@return WaxSlider
function Container:Slider(caption, options, on_change) end

---Adds a text box. on_commit(text) runs when Enter is pressed or the box loses focus.
---@param caption? string
---@param options? WaxInputOptions
---@param on_commit? fun(text: string)
---@return WaxInput
function Container:Input(caption, options, on_commit) end

---Adds a dropdown that opens in place. on_change(choice) runs when the user picks one.
---@generic T
---@param caption string
---@param choices T[]
---@param selected? T The first choice when omitted.
---@param on_change? fun(choice: T)
---@return WaxDropdown
function Container:Dropdown(caption, choices, selected, on_change) end

---Adds a collapsible card and returns it as a container: section:Button(...), section:Toggle(...) and so on.
---@param title string
---@param options? WaxSectionOptions
---@return WaxSection
function Container:Section(title, options) end

---Adds a title for a page or a group of controls: large text, an optional explanation, and a rule under it.
---@param content string
---@param description? string
---@return WaxTitle
function Container:Title(content, description) end

---Adds a row. Controls added to the returned container sit side by side and share the width.
---@return WaxRow
function Container:Row() end

---A colour the user can change.
---@param caption string
---@param color? string "#rrggbb". White when omitted.
---@param on_change? fun(color: string)
---@return WaxColorControl
function Container:Color(caption, color, on_change) end

---@class WaxGridOptions : WaxOptions
---@field make fun(cell: WaxContainer): any Called once for each cell that is needed: add one control to `cell` and return whatever `show` needs.
---@field show fun(made: any, item: any, index: integer) Called whenever a cell is to show another item.
---@field items? any[] The list to show, of any length.
---@field cell? number Least width of a cell. Default 38. As many columns as fit share the width.
---@field cell_height? number Default: the same as `cell`.
---@field height? number Default 300. On a page made with scroll = false the grid takes the space left when omitted.

---A grid for any number of items: only the cells in view exist, and they are reused as it scrolls. It follows its scrolling while the menu is open, so it belongs in a window, not in an overlay.
---@class WaxGrid: WaxControl
local Grid = {}

---Shows another list, from the top.
---@param items any[]
function Grid:SetItems(items) end

---Shows every cell again, after the items themselves changed.
function Grid:Refresh() end

---How many items the grid has.
---@return integer
function Grid:Count() end

---@class WaxFlowOptions : WaxOptions
---@field cell? number Makes it a grid: every control gets the same width, at least this, and each line is full.

---Adds a grid for any number of items. It builds only the cells in view, with the `make` and `show` functions in `options`.
---@param options WaxGridOptions
---@return WaxGrid
function Container:Grid(options) end

---Adds an area where controls keep their own size and wrap onto new lines. Add them to the returned container.
---@param options? WaxFlowOptions
---@return WaxRow
function Container:Flow(options) end

---Adds a progress bar. value is 0..1.
---@param caption string
---@param value? number
---@param options? WaxProgressOptions
---@return WaxProgress
function Container:Progress(caption, value, options) end

---Adds a name with a value on the right, for read-outs.
---@param name string
---@param value? any
---@param options? WaxFieldOptions
---@return WaxField
function Container:Field(name, value, options) end

---Adds a key the user can rebind by clicking it and pressing a key. on_change(key) gets the engine's key name.
---@param caption string
---@param key? string
---@param on_change? fun(key: string)
---@return WaxKeybind
function Container:Keybind(caption, key, on_change) end

---Adds a scrolling list of text lines, such as a log.
---@param options? WaxConsoleOptions
---@return WaxConsole
function Container:Console(options) end
