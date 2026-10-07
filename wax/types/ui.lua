---@meta _

---Stands for any key an options table does not list, so that the editor reports a misspelt option.
---@class WaxUnknownOption

---The base of every options table.
---@class WaxOptions
---@field [string] WaxUnknownOption

---A colour in the linear form the engine uses. Make one with ui.Color.
---@class WaxColor
---@field R number
---@field G number
---@field B number
---@field A number

---@alias WaxKind "info"|"good"|"warn"|"bad"
---@alias WaxCorner "top-left"|"top-right"|"bottom-left"|"bottom-right"
---@alias WaxAnchor "top-left"|"top"|"top-right"|"left"|"center"|"right"|"bottom-left"|"bottom"|"bottom-right"
---@alias WaxNav "side"|"top"
---@alias WaxFontFamily "ui"|"mono"|"plain"
---@alias WaxThemeName "Midnight"|"Graphite"|"Abyss"|"Dune"|"Prospector"|"Ember"|"Aurora"|"Nebula"|"Rosewood"|"Terminal"|"Daylight"|"Glacier"|"Sandstone"|string

---@alias WaxShape
---| "frame6"
---| "frame8"
---| "frame12"
---| "top8"
---| "glow12"
---| "glow12_soft"
---| "round2"
---| "round3"
---| "round4"
---| "round5"
---| "round6"
---| "round7"
---| "round8"
---| "round9"
---| "round10"
---| "round12"

---The theme in use. Its colours change in place when the theme changes, so a colour taken from here (ui.Theme().good)
---follows the theme wherever you used it. Change the theme with ui.SetTheme, not by writing to this table.
---@class WaxTheme
---@field window WaxColor Window background.
---@field outline WaxColor Window outline.
---@field panel WaxColor Text boxes, dropdown lists and consoles.
---@field card WaxColor Section background.
---@field card_line WaxColor Section outline.
---@field raised WaxColor Buttons and tracks.
---@field hover WaxColor
---@field press WaxColor
---@field line WaxColor Separators.
---@field text WaxColor
---@field dim WaxColor Secondary text.
---@field accent WaxColor
---@field accent_hover WaxColor
---@field good WaxColor
---@field warn WaxColor
---@field bad WaxColor
---@field clear WaxColor Fully transparent.
---@field on_accent WaxColor Text and knobs drawn on top of the accent colour.
---@field font_size number
---@field title_size number
---@field small_size number
---@field spacing number Gap between controls.
---@field padding number
---@field row_height number
---@field bar_height number Height of a window's title bar.
---@field nav_width number Default width of a side navigation column.
---@field window_shape WaxShape
---@field control_shape WaxShape
---@field animation number Seconds for open, close and expand animations. 0 turns animation off.

---Theme settings to change. Colours may be given as "#RRGGBB" or 0xRRGGBB.
---@class WaxThemeSettings: WaxOptions
---@field window? WaxColor|string|integer
---@field outline? WaxColor|string|integer
---@field panel? WaxColor|string|integer
---@field card? WaxColor|string|integer
---@field card_line? WaxColor|string|integer
---@field raised? WaxColor|string|integer
---@field hover? WaxColor|string|integer
---@field press? WaxColor|string|integer
---@field line? WaxColor|string|integer
---@field text? WaxColor|string|integer
---@field dim? WaxColor|string|integer
---@field accent? WaxColor|string|integer
---@field accent_hover? WaxColor|string|integer
---@field good? WaxColor|string|integer
---@field warn? WaxColor|string|integer
---@field bad? WaxColor|string|integer
---@field clear? WaxColor|string|integer
---@field on_accent? WaxColor|string|integer
---@field font_size? number
---@field title_size? number
---@field small_size? number
---@field spacing? number
---@field padding? number
---@field row_height? number
---@field bar_height? number
---@field nav_width? number
---@field window_shape? WaxShape
---@field control_shape? WaxShape
---@field animation? number

---@class WaxWindowOptions: WaxOptions
---@field title? string "Window" when omitted.
---@field icon? string Icon name shown before the title. The menu's Icons page lists the names.
---@field width? number Default 340, or 520 with side navigation.
---@field height? number Default 420, or 380 with pages.
---@field x? number
---@field y? number
---@field closable? boolean False leaves out the close button.
---@field visible? boolean False creates the window hidden.
---@field nav? WaxNav Gives the window pages, listed down the side or along the top.
---@field nav_width? number Width of the side navigation column.
---@field remember? boolean False stops Wax remembering the window's position and size between sessions.

---@class WaxPageOptions: WaxOptions
---@field icon? string Icon name shown before the page's name. The menu's Icons page lists the names.
---@field bottom? boolean Lists the page at the bottom of a side navigation column.
---@field scroll? boolean False makes a page that does not scroll. Its controls stack from the top, and a Grid or Console with no height takes the space left.

---A page of a window that has navigation. It is a container for controls.
---@class WaxPage: WaxContainer
---@field NearEnd WaxSignal<fun()> Fires while the end of the page is in view: when the user scrolls close to the bottom, and a few times a second while the page is not full. Add more content in the handler, or do nothing when there is no more.

---A window in the menu. Controls added to it go into its body, or into a first page called "Main" when it has pages.
---@class WaxWindow: WaxContainer
---@field Opened WaxSignal<fun()> Fires when the window is shown.
---@field Closed WaxSignal<fun()> Fires when the window is hidden.
---@field PageChanged WaxSignal<fun(name: string)> Fires with the name of the page that was selected.
local Window = {}

---Changes the text in the title bar.
---@param title string
function Window:SetTitle(title) end

---Moves the window, keeping it on the screen.
---@param x number
---@param y number
function Window:SetPosition(x, y) end

---Resizes the window, no smaller than its minimum size.
---@param width number
---@param height number
function Window:SetSize(width, height) end

---Sets the width of the navigation column of a window made with nav = "side".
---@param width number
function Window:SetNavWidth(width) end

---Shows the window, in front of the others.
function Window:Show() end

---Hides the window. Hiding the last one closes the menu.
function Window:Hide() end

---Shows or hides the window.
---@param shown boolean
function Window:SetVisible(shown) end

---True while the window is shown.
---@return boolean
function Window:IsVisible() end

---Minimises the window to its title bar, or restores it.
---@param minimized boolean
function Window:SetMinimized(minimized) end

---True while the window is minimised.
---@return boolean
function Window:IsMinimized() end

---Adds a status line along the bottom of the window, or returns the one the window already has. `text` sets its message.
---@param text? any
---@return WaxStatusBar
function Window:StatusBar(text) end

---Removes the window and everything on it.
function Window:Destroy() end

---Adds a page to a window made with nav = "side" or "top". The first page added is selected.
---@param name string
---@param options? WaxPageOptions
---@return WaxPage
function Window:Page(name, options) end

---Removes a page made with Page, with everything on it.
---@param page WaxPage
function Window:RemovePage(page) end

---Switches to the page with this name.
---@param name string
function Window:SelectPage(name) end

---@class WaxStatusOptions: WaxOptions
---@field kind? WaxKind Sets the colour of the text and the icon. "info" when omitted.
---@field icon? string Icon name shown before the text. The menu's Icons page lists the names.

---The line along the bottom of a window that Window:StatusBar returns.
---@class WaxStatusBar
local StatusBar = {}

---Shows a message and removes the busy indicator.
---@param message? any
---@param options? WaxStatusOptions
function StatusBar:Set(message, options) end

---Shows a message with a turning indicator beside it, until the next Set.
---@param message? any
function StatusBar:Busy(message) end

---Shows a thin progress line across the top of the bar. `amount` is 0..1, and nil hides the line.
---@param amount? number
function StatusBar:Progress(amount) end

---Shows text at the right-hand end of the bar.
---@param message? any
function StatusBar:Right(message) end

---Empties the message and hides the progress line.
function StatusBar:Clear() end

---@class WaxOverlayOptions: WaxOptions
---@field anchor? WaxAnchor Where on the screen the panel is pinned. "top-right" when omitted.
---@field x? number Distance in from the anchor's edge. Default 16.
---@field y? number Distance in from the anchor's edge. Default 16.
---@field width? number Default 240.
---@field title? string Adds a heading.
---@field background? boolean False leaves out the panel behind the controls.
---@field movable? boolean False stops the player dragging it while the menu is open. Where it was dragged to is remembered.

---A panel pinned to the screen that stays up during play and never takes the mouse.
---@class WaxOverlay: WaxContainer
---@field Scrolled WaxSignal<fun(steps: integer)> On a panel made with ui.Panel: the wheel was turned over it, 1 for down and -1 for up. The game does not see the wheel while the mouse is over a panel.
local Overlay = {}

---Shows or hides the overlay.
---@param shown boolean
function Overlay:SetVisible(shown) end

---True while the overlay is shown.
---@return boolean
function Overlay:IsVisible() end

---Pins the overlay somewhere else. x and y keep their values when omitted.
---@param anchor WaxAnchor
---@param x? number
---@param y? number
function Overlay:SetAnchor(anchor, x, y) end

---Removes the overlay and everything on it.
function Overlay:Destroy() end

---Moves it without changing its anchor. x and y keep their values when omitted.
---@param x? number
---@param y? number
function Overlay:SetOffset(x, y) end

---True while it is really on screen: switched on, and what it waits for (the menu, the mouse) is there.
---@return boolean
function Overlay:IsShowing() end

---@class WaxPanelOptions: WaxOverlayOptions
---@field when? "cursor"|"menu"|"always" When it shows: "cursor" (the default) while the Wax menu is open or one of the game's own screens has the mouse, "menu" only with the Wax menu, "always" whenever it is switched on.
---@field padding? number Space between its edge and its controls.
---@field height? number A fixed height. As tall as its controls when omitted.
---@field zoom? number Draws everything in it this much larger (1.25 is a quarter larger). Text stays sharp.
---@field opacity? number How solid its background is, 0 to 1. 0.96 when omitted.
---@field visible? boolean False makes it hidden until SetVisible(true).
---@field on_press? fun() Runs when the panel is pressed where it has no control.

---@class WaxFitOptions: WaxOptions
---@field scale? number How large the game's menus are drawn, 0.5 to 1. 0.85 when omitted.
---@field corner? WaxAnchor The corner they shrink towards. "bottom-left" when omitted, which frees the right and the top.
---@field x? number Moves them sideways after they are made smaller, as a share of the screen. Right is positive.
---@field y? number Moves them up or down after they are made smaller, as a share of the screen. Down is positive.
---@field enabled? boolean False makes the request wait for SetEnabled(true).

---A request to draw the game's own menus smaller.
---@class WaxFit
local Fit = {}

---@param scale number
---@param x? number Keeps its value when omitted.
---@param y? number Keeps its value when omitted.
function Fit:Set(scale, x, y) end

---@param on boolean
function Fit:SetEnabled(on) end

---Gives the game's menus their own size back.
function Fit:Remove() end

---@class WaxPictures
local Pictures = {}

---The game path of a picture as it can be shown ("/Game/.../ITEM_Wood.ITEM_Wood"), or nil when the text is not one.
---@param path string
---@return string?
function Pictures.Check(path) end

---How many game pictures were loaded, failed, are waiting and are kept in memory.
---@return { loaded: integer, failed: integer, waiting: integer, pinned: integer, worst_ms: number }
function Pictures.Stats() end

---@class WaxNotifyOptions: WaxOptions
---@field title? string A bold line above the text.
---@field kind? WaxKind Sets the colour and the icon. "info" when omitted.
---@field icon? string Icon name used in place of the kind's own. The menu's Icons page lists the names.
---@field seconds? number Time on screen. Default 4, and 0 keeps it until closed.
---@field progress? number 0..1. Shows progress in place of the countdown and keeps the notification until closed.

---@class WaxNotification
local Notification = {}

---Replaces the text.
---@param text any
function Notification:SetText(text) end

---Replaces the title. Does nothing on a notification made without one.
---@param title string
function Notification:SetTitle(title) end

---Shows how far a task is, 0..1, in place of the countdown. The notification then stays until closed.
---@param amount number
function Notification:SetProgress(amount) end

---Closes the notification.
function Notification:Close() end

---@class WaxNotifications
local Notifications = {}

---Moves notifications to another corner of the screen, closing the ones showing.
---@param name WaxCorner
function Notifications.SetCorner(name) end

---Sets how many notifications show at once (at least 1).
---@param count number
function Notifications.SetLimit(count) end

---Closes every notification.
function Notifications.Clear() end

---How many notifications are showing.
---@return integer
function Notifications.Count() end

---Icon names: the bundled Lucide set ("shield", "wrench", "map-pin" ...) plus images that mods register.
---@class WaxIcons
local Icons = {}

---Every icon name, sorted. The menu's Icons page shows them.
---@return string[]
function Icons.Names() end

---True when there is an icon with this name.
---@param name string
---@return boolean
function Icons.Has(name) end

---Names containing the text, at most `limit` of them (every name when the text is empty).
---@param text? string
---@param limit? integer
---@return string[]
function Icons.Find(text, limit) end

---Adds an icon from a PNG file. White on transparent works best, because the icon is tinted when drawn.
---@param name string
---@param file string
function Icons.Register(name, file) end

---The in-game debug panel.
---@class WaxDebugPanel
local Debug = {}

---Adds a page to the debug panel for the calling mod. The page is removed when the mod reloads.
---@param name string
---@param options? WaxPageOptions
---@return WaxPage
function Debug.Page(name, options) end

---The debug panel's window, or nil while the panel is not running.
---@return WaxWindow?
function Debug.Window() end

---Shows the debug panel and opens the menu.
function Debug.Show() end

---The GUI library: the menu (windows you click), overlays (panels you only read) and notifications.
---@class WaxUI
---@field Opened WaxSignal<fun()> Fires when the menu opens.
---@field Closed WaxSignal<fun()> Fires when the menu closes.
---@field KeyChanged WaxSignal<fun(key: string?)> Fires with the new menu key.
---@field ThemeChanged WaxSignal<fun(name: string)> Fires with the theme's name after SetTheme or ResetTheme.
---@field ScreenChanged WaxSignal<fun(width: number, height: number)> Fires when ScreenSize gives another answer: a new resolution or interface scale.
---@field Icons WaxIcons
---@field Notifications WaxNotifications
---@field Debug WaxDebugPanel
---@field Pictures WaxPictures
ui = {}

---Opens the menu: windows appear and the mouse is freed to use them.
---@param options? { windows: boolean? } `windows = false` frees the mouse for panels only and leaves the windows hidden.
function ui.Open(options) end

---Closes the menu and gives the mouse back to the game.
function ui.Close() end

---Opens the menu when it is closed, and closes it when it is open.
function ui.Toggle() end

---Puts text on the clipboard, for pasting anywhere.
---@param text any
function ui.Copy(text) end

---True while the menu is open.
---@return boolean
function ui.IsOpen() end

---Shows the windows without taking the mouse (for screenshots and for looking while you play).
---@param on boolean
function ui.SetPreview(on) end

---True while the windows are shown in preview.
---@return boolean
function ui.IsPreview() end

---Sets the key that opens and closes the menu, by the engine's key name ("F8"). nil leaves the menu without a key.
---@param key string?
function ui.SetToggleKey(key) end

---The key that opens and closes the menu.
---@return string?
function ui.GetToggleKey() end

---Creates a window in the menu. It is removed again when the mod reloads.
---@param options? WaxWindowOptions
---@return WaxWindow
function ui.Window(options) end

---Creates a panel pinned to the screen that stays up during play and lets clicks through.
---@param options? WaxOverlayOptions
---@return WaxOverlay
function ui.Overlay(options) end

---Creates a panel whose controls take the mouse. It has no title bar and shows beside the game's own screens.
---@param options? WaxPanelOptions
---@return WaxOverlay
function ui.Panel(options) end

---The value of the slot under the mouse, then its look and its Slots control. Nothing when no slot is under it.
---@return any value
---@return WaxSlotLook? look
---@return WaxSlots? control
function ui.Hovered() end

---True while a text box of Wax has the keyboard.
---@return boolean
function ui.IsTyping() end

---The size of the screen in the units windows and panels are laid out in. While the game is starting and has no
---screen yet, the answer is 1920 by 1080; ScreenChanged fires if the real one turns out different.
---@return number width
---@return number height
function ui.ScreenSize() end

---Draws the game's own menus (inventory, crafting, benches) smaller, which leaves room beside them for panels.
---They keep working as before. The request ends when the mod reloads.
---@param options? WaxFitOptions
---@return WaxFit
function ui.FitGame(options) end

---The game's own menu screen that is showing now: "UMG_MainMenu", "UMG_EscapeMenu", or a bench or container such as
---"UMG_Processor_C". For the main menu the second value is its tab: 0 inventory, 1 crafting, 2 tech tree, 3 talents, 4 map.
---Nothing when none shows.
---@return string? name
---@return integer? tab
function ui.GameScreen() end

---@class WaxTagOptions: WaxOptions
---@field text? string
---@field color? WaxColor|string
---@field size? number
---@field within? number Metres. Farther away than this the tag is not shown. Default 100.
---@field lift? number How far above the thing's middle the tag sits, in centimetres. Worked out from the thing when omitted.

---A line of text that stays over something in the world.
---@class WaxTag
---@field Instance WaxInstance? What the tag is on. nil for a tag on a spot.
local Tag = {}

---@param text string
function Tag:Set(text) end

---@param color WaxColor|string
function Tag:SetColor(color) end

---@param metres number
function Tag:SetRange(metres) end

---Takes the tag off. Safe to call twice, and after the thing it was on is gone.
function Tag:Remove() end

---Puts a line of text over an actor, over one part of an actor, or on a spot in the world.
---It follows what it is on, shows through walls, and tags that would cover each other pile up.
---The tag goes away by itself when the actor does.
---@param target WaxInstance|{ X: number, Y: number, Z: number }
---@param options? WaxTagOptions
---@return WaxTag
function ui.Tag(target, options) end

---Shows a short message in a corner of the screen. Sending the same message again restarts the one already showing.
---@param text any
---@param options? WaxNotifyOptions
---@return WaxNotification
function ui.Notify(text, options) end

---A list of every window.
---@return WaxWindow[]
function ui.Windows() end

---@class WaxHotkeyOptions : WaxOptions
---@field in_menu? boolean Also reacts while the menu is open (off by default, so that typing in a box does not trigger it).
---@field typing? boolean Also reacts while a text box has the keyboard (for a key meant for the box, such as Tab).
---@field hover? boolean Makes it a key for the slot under the mouse: it only reacts while a slot is under it.

---@class WaxHotkey
local Hotkey = {}

---Stops the hotkey.
function Hotkey.Disconnect() end

---Changes the key it reacts to.
---@param key string
function Hotkey:SetKey(key) end

---Runs `callback` when the key is pressed during play. The hotkey is removed when the mod reloads.
---@param key string An engine key name such as "F6", "K" or "MiddleMouseButton" (a Keybind control gives you these). It can be held with Ctrl, Shift or Alt: "Ctrl+Three", "Ctrl+Shift+K".
---@param callback fun()
---@param options? WaxHotkeyOptions
---@return WaxHotkey
function ui.Hotkey(key, callback, options) end

---The smallest scale that still draws text at a readable size on this screen.
---@return number
function ui.MinScale() end

---Sets the interface size, where 1 is normal. The size is kept between ui.MinScale() and 2, and the size applied is returned.
---@param scale number
---@return number applied
function ui.SetScale(scale) end

---The interface size in use.
---@return number
function ui.GetScale() end

---Switches to a named theme, or changes single settings from a table. Everything on screen takes the new colours in place, so no window is rebuilt and no mod is reloaded. Sizes and shapes apply to what is built afterwards.
---@param theme WaxThemeName|WaxThemeSettings
function ui.SetTheme(theme) end

---Puts every theme setting back to the "Midnight" defaults.
function ui.ResetTheme() end

---The names of the built-in themes, then of the ones added with AddTheme.
---@return string[]
function ui.Themes() end

---Adds a theme: a table with any of the colour settings (window, panel, raised, text, accent ...) as "#RRGGBB".
---@param name string
---@param colors WaxThemeSettings
function ui.AddTheme(name, colors) end

---The name of the theme in use.
---@return string
function ui.ThemeName() end

---Makes a colour from "#RRGGBB" or 0xRRGGBB, with an optional alpha of 0..1.
---@param hex string|integer
---@param alpha? number
---@return WaxColor
function ui.Color(hex, alpha) end

---The table of the theme in use. Its colours follow the theme, so pass them as they are (color = ui.Theme().accent).
---@return WaxTheme
function ui.Theme() end

---Adds the menu's own settings (key, theme, accent, animation, size) to a container, such as a "Settings" page.
---@param container WaxContainer
function ui.AddSettings(container) end
