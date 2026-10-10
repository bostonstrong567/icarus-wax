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
---@field resizable? boolean False makes a window the player cannot resize: it has no grip, its edges and corners do nothing, and it is always the size your mod gives it. SetSize still works.
---@field visible? boolean False creates the window hidden.
---@field nav? WaxNav Gives the window pages, listed down the side or along the top.
---@field nav_width? number Width of the side navigation column.
---@field remember? boolean False stops Wax remembering the window's position and size between sessions.
---@field pinned? boolean True keeps the window on the screen while the player plays, with the menu closed. It takes no clicks then, so the mouse stays with the game. With a menu open it is a window like any other.
---@field key? string The key that shows and hides your mod's windows, such as "F6" or "Ctrl+K". The first window a mod makes decides. Without it Wax gives the mod a key, and the player can choose another on the mod's card of the Mods page.

---@class WaxPageOptions: WaxOptions
---@field icon? string Icon name shown before the page's name. The menu's Icons page lists the names.
---@field bottom? boolean Lists the page at the bottom of a side navigation column.
---@field scroll? boolean False makes a page that does not scroll. Its controls stack from the top, and a Grid or Console with no height takes the space left.

---A page of a window that has navigation. It is a container for controls.
---@class WaxPage: WaxContainer
---@field PressedAgain WaxSignal<fun()> Fires when the page's own name is pressed while the page is already showing. Use it to go back to the start of a page that has several views.
---@field NearEnd WaxSignal<fun()> Fires while the end of the page is in view: when the user scrolls close to the bottom, and a few times a second while the page is not full. Add more content in the handler, or do nothing when there is no more.

---A window in the menu. Controls added to it go into its body, or into a first page called "Main" when it has pages.
---The player moves it by its title bar and resizes it by any edge or corner; the bottom right corner shows a grip. Resizing stops at the window's minimum size and at the edges of the screen.
---A mod's windows come up together, with that mod's key (see ui.Keys), and other mods' windows stay as they are.
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

---Shows the window, in front of the others. While the menu is open it comes up at once, with your mod's other windows. While the menu is closed it waits for your mod's key or for ui.Open().
function Window:Show() end

---Hides the window. Hiding the last window that is up closes the menu.
function Window:Hide() end

---Shows or hides the window.
---@param shown boolean
function Window:SetVisible(shown) end

---True while the window is shown. A shown window is on screen only while its mod's windows are up: IsShowing tells you that.
---@return boolean
function Window:IsVisible() end

---True while the window is really on screen: it is shown, and its mod's windows are up (or every window is, in preview).
---@return boolean
function Window:IsShowing() end

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
---@field Resized WaxSignal<fun(width: number, height: number?)> On a panel made with a place function: it was given another size, in its own units. Fires in the frame the screen changed.
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
---@field place? fun(screen_width: number, screen_height: number): WaxPanelPlace Where the panel goes on a screen of this size. It is asked when the panel is made and again, in the same frame, whenever the game's window changes size: the panel that exists is moved, sized and zoomed, and nothing is built again. The size is the real screen in the units the game lays its own menus out in, and the zoom is used as it is, so such a panel keeps its size beside the game's menus whatever the interface size is.

---What a panel's place function answers. What is left out stays as it is.
---@class WaxPanelPlace
---@field x? number
---@field y? number
---@field width? number
---@field height? number
---@field zoom? number

---@class WaxFitOptions: WaxOptions
---@field scale? number How large the game's menus are drawn, 0.5 to 1. 0.85 when omitted.
---@field corner? WaxAnchor The corner they shrink towards. "bottom-left" when omitted, which frees the right and the top.
---@field x? number Moves them sideways after they are made smaller, as a share of the screen. Right is positive.
---@field y? number Moves them up or down after they are made smaller, as a share of the screen. Down is positive.
---@field enabled? boolean False makes the request wait for SetEnabled(true).

---A request to draw the game's own menus smaller.
---@class WaxFit
local Fit = {}

---Changes how large the game's menus are drawn, and how far they are moved when x or y is given.
---The numbers mean what the `scale`, `x` and `y` options mean.
---@param scale number
---@param x? number Keeps its value when omitted.
---@param y? number Keeps its value when omitted.
function Fit:Set(scale, x, y) end

---Switches the request on or off. While it is off the game's menus have their own size, unless another request is on.
---@param on boolean
function Fit:SetEnabled(on) end

---Gives the game's menus their own size back.
function Fit:Remove() end

---The game's own pictures, such as item icons, which a cell of a Slots control shows by their path.
---Loading them is given a few milliseconds a frame, so a picture can show a moment after it was asked for.
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

---One message in a corner of the screen, as ui.Notify returns it. Once it has closed, its functions do nothing.
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

---What all notifications share: the corner they show in and how many show at once. It also counts them and closes them all.
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

---Shows the Wax panel and frees the mouse, whichever mod calls it. Your own windows stay as they are.
function Debug.Show() end

---One owner of windows, as ui.Keys.Owners lists it.
---@class WaxKeyOwner
---@field id string "Wax" for Wax's own panel, else the id of a mod.
---@field name string The name to show: "Wax", or the mod's name.
---@field key string? Its key, or nil when it has none.
---@field open boolean True while its windows are up.

---The keys that show and hide windows. Wax's own panel has one, and so has every mod that made a window: a key shows
---and hides its owner's windows and nobody else's. A mod's key is the one the player chose on the mod's card of the
---Mods page, else the one the mod asked for with ui.Window({ key = "F6" }), else a key Wax gives it once and remembers:
---one that no window and no hotkey of any mod uses. A press that your mod's own ui.Hotkey takes is not also taken as
---the key of its windows.
---@class WaxKeys
---@field Changed WaxSignal<fun(owner: string, key: string?)> Fires with the owner and its new key when a key is changed.
---@field BindChanged WaxSignal<fun(owner: string, name: string, key: string?)> Fires when a named key of a mod is given another key.
local Keys = {}

---The key of an owner: "Wax" or a mod's id. Left out, it is the mod that asks.
---@param owner? string
---@return string?
function Keys.Get(owner) end

---Gives an owner another key, or none with nil. A key that another owner has, or that another mod uses as a hotkey, is given all the same: a notification says who else has it, the Mods page shows the clash, and the second value is that name.
---@param owner string "Wax" or a mod's id.
---@param key string? An engine key name such as "F6". It can be held with Ctrl, Shift or Alt: "Ctrl+K".
---@return boolean changed
---@return string? taken_by
function Keys.Set(owner, key) end

---The key a mod's mod.lua names for its windows (`key = "F6"`), as the player has it now. nil when mod.lua names none. It is known while the mod is not running.
---@param owner string A mod's id.
---@return string?
function Keys.Named(owner) end

---Every owner that has a window, Wax first.
---@return WaxKeyOwner[]
function Keys.Owners() end

---One named key of a mod, as ui.Keys.Binds lists it.
---@class WaxKeyBind
---@field Id string The mod's id.
---@field Name string The name the mod gave the key.
---@field Label string What the mod's card calls it.
---@field Key string? The key it has now. nil when the player left it without one.
---@field Default string? The key the mod asked for.
---@field Declared boolean? true when the mod is not running and the key is known from its mod.lua.

---The named keys mods made with ui.Bind. With a mod's id, only that mod's, and for a mod that is not running the keys its mod.lua names.
---@param owner? string
---@return WaxKeyBind[]
function Keys.Binds(owner) end

---Gives a named key of a mod another key, or none with nil, and remembers it for that player. A key somebody else uses is taken all the same: a notification says who else has it, and ui.Keys.Clashes lists it.
---@param owner string A mod's id.
---@param name string The name the mod gave the key.
---@param key string? An engine key name such as "F10" or "Ctrl+K".
---@return boolean changed
function Keys.SetBind(owner, name, key) end

---The keys that more than one owner acts on, one line of text for each: the Wax panel's key, the key of each mod's windows, every named key and every plain hotkey of a mod. With an owner, only the clashes that owner is part of, said from its side. An empty list when nothing clashes.
---@param owner? string "Wax" or a mod's id.
---@return string[]
function Keys.Clashes(owner) end

---The GUI library: the menu (windows you click), overlays (panels you only read) and notifications.
---@class WaxUI
---@field Opened WaxSignal<fun()> Fires when the menu opens: somebody's windows come up and the mouse is freed.
---@field Closed WaxSignal<fun()> Fires when the menu closes: nobody's windows are up any more and the game has the mouse back. A mod that opened the menu with `windows = false` also hears it when its own ui.Close() leaves the menu open for others.
---@field KeyChanged WaxSignal<fun(key: string?)> Fires with the new key of Wax's own panel. For any owner's key, use ui.Keys.Changed.
---@field ThemeChanged WaxSignal<fun(name: string)> Fires with the theme's name after SetTheme or ResetTheme.
---@field ScreenChanged WaxSignal<fun(width: number, height: number)> Fires once with the new size when ScreenSize gives another answer: after the game's window or the interface size has stopped changing for a moment, never while it is still being resized.
---@field GameScreenChanged WaxSignal<fun(name: string?, tab: integer?)> Fires with what GameScreen answers, in the frame the game shows another of its menu screens, another tab of its main menu, or none any more (nil). Connect to it in place of asking GameScreen every frame: the game is only looked at while somebody listens.
---@field Icons WaxIcons
---@field Notifications WaxNotifications
---@field Debug WaxDebugPanel
---@field Pictures WaxPictures
---@field Keys WaxKeys
ui = {}

---Shows your mod's windows and frees the mouse to use them. Other mods' windows and the Wax panel stay as they are. In the command bar it is the Wax panel that comes up.
---@param options? { windows: boolean? } `windows = false` frees the mouse for panels only and brings no window up.
function ui.Open(options) end

---Hides your mod's windows again. The menu closes, and the game has the mouse back, once nobody's windows are up.
function ui.Close() end

---Shows your mod's windows when they are away, and hides them when they are up.
function ui.Toggle() end

---Puts text on the clipboard, for pasting anywhere.
---@param text any
function ui.Copy(text) end

---@class WaxTextOptions
---@field size? number The font size. The interface's own when omitted.
---@field face? string "Bold", "Book" or "Medium" (the default).
---@field family? string "mono" for the fixed-width font.

---How wide a line of text is drawn, in the units controls and panels are sized in. It is worked out from the letters, to within a few percent.
---@param text any
---@param options? WaxTextOptions
---@return number width
function ui.TextWidth(text, options) end

---The text if it fits in a width, else its start with "..." after it. A little room is kept spare, as the library does for its own text.
---@param text any
---@param width number
---@param options? WaxTextOptions
---@return string shown
---@return boolean cut True when the text did not fit.
function ui.Shorten(text, width, options) end

---True while the menu is open: the mouse is free, because somebody's windows are up.
---@return boolean
function ui.IsOpen() end

---Shows every window without taking the mouse (for screenshots and for looking while you play).
---@param on boolean
function ui.SetPreview(on) end

---True while the windows are shown in preview.
---@return boolean
function ui.IsPreview() end

---Sets the key that shows and hides Wax's own panel, by the engine's key name ("F8"). nil leaves the panel without a key. A key that somebody has is given all the same, with a notice, as with ui.Keys.Set. Every mod has a key of its own: see ui.Keys.
---@param key string?
---@return boolean changed
---@return string? taken_by
function ui.SetToggleKey(key) end

---The key that shows and hides Wax's own panel.
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

---The size of the screen in the units windows and panels are laid out in. It changes with the shape of the game's
---window and with the interface size. While the game is starting and has no screen yet, the answer is 1920 by 1080;
---ScreenChanged fires if the real one turns out different.
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

---Replaces the text.
---@param text string
function Tag:Set(text) end

---Changes the colour of the text.
---@param color WaxColor|string
function Tag:SetColor(color) end

---Sets how near the thing has to be for the tag to show, in metres.
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

---A key that runs a function when it is pressed, as ui.Hotkey returns it.
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

---A named key of your mod, as ui.Bind returns it.
---@class WaxBind
---@field Changed WaxSignal<fun(key: string?)> Fires with the new key when the player, or your mod, changes it.
local Bind = {}

---The key it has now. nil when the player left it without one.
---@return string?
function Bind:Get() end

---Gives it another key, or none with nil, as the player does on the mod's card.
---@param key string?
---@return boolean changed
function Bind:Set(key) end

---Takes the key away from your mod. It also goes when the mod unloads.
function Bind:Disconnect() end

---The options of ui.Bind.
---@class WaxBindOptions
---@field label? string What the mod's card calls the key. The name when omitted.
---@field in_menu? boolean true lets it run while the menu is open as well.
---@field typing? boolean true lets it run while a text box has the keyboard.

---A hotkey with a name. It runs callback when its key is pressed, like ui.Hotkey, and it is listed on your mod's card of the Mods page, where the player can give it another key. The player's choice is remembered and used the next time, so `key` is only where it starts. When two mods act on one key both still run, and the Mods page says which keys clash. Use it for every key a player might want to change.
---@param name string A name for the key that stays the same between versions, such as "Open". One mod cannot have two of one name.
---@param key string? The key it starts with, such as "F10" or "Ctrl+K". nil takes the key mod.lua names for it in `keys`, or none until the player gives one.
---@param callback fun()
---@param options? WaxBindOptions
---@return WaxBind
function ui.Bind(name, key, callback, options) end

---True while the key is held down, as the game's own input reports it for the local player. It takes the key names
---ui.Hotkey takes. A name with Ctrl, Shift or Alt ("Ctrl+K") is true only while the key is down with exactly those
---held; a plain name is true whatever else is held. It is false while the game has no local player, and for a name
---the game does not know. It does not look at whether the menu is open or a text box has the keyboard (see
---ui.IsTyping). Every call asks the game, so use it in a loop that runs while something is held, such as one a
---ui.Hotkey started, and not in every frame of the game. It raises an error for a key that is not text, for empty
---text, and for a word before the key that is not Ctrl, Shift or Alt.
---@param key string An engine key name such as "A", "LeftShift" or "MiddleMouseButton".
---@return boolean
function ui.IsKeyDown(key) end

---The smallest interface size that still draws text at a readable size on this screen. It follows the size of the game's window.
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

---Adds Wax's own settings (the key of its panel, theme, accent, animation, size) to a container, such as a "Settings" page.
---@param container WaxContainer
function ui.AddSettings(container) end

---The fur of a model: a second mesh that hair grows from. game.Creatures:GetModel fills it in from the creature's own data.
---@class WaxModelFur
---@field mesh string The game path of the mesh the fur grows from.
---@field splines? string The game path of the fur's splines.
---@field layers? integer How many layers the fur is drawn in, 1 to 64.
---@field length? number
---@field min_length? number
---@field bias? number
---@field noise? number
---@field hair_bias? number
---@field uniformity? number
---@field bare? boolean True leaves out the faces that have no splines.
---@field materials? table<integer, string> Game paths of materials by slot, 1 first.
---@field mask? string The game path of a texture that says where no fur grows, as the game puts one on a mount's fur under some saddles. It goes on a copy of the fur's first material, so it only works when materials names that one.

---One more mesh of a model, such as a piece of armour or a saddle. With nothing but a mesh it takes the pose of the first mesh, bone by bone.
---With a blueprint or a socket it is put on as the game puts a saddle on its mount: attached to the first mesh, and posed by its own blueprint.
---@class WaxModelPart
---@field mesh string The game path of a skeletal mesh.
---@field materials? table<integer, string> Game paths of materials by slot, 1 first.
---@field blueprint? string The game path of the part's own animation blueprint, one that copies the pose of another mesh, as every saddle of the game has. The part is attached to the first mesh and the blueprint is given that mesh to copy. When it cannot be loaded the part takes the first mesh's pose bone by bone instead.
---@field socket? string A socket or a bone of the first mesh the part sits on, such as "RaptorSaddle". Left out, it sits on the mesh itself. A part on a socket is not counted when the model is fitted to its box.

---What a Model control shows. Every path is a game path such as "/Game/ASS/CRE/Deer/SK_CRE_PAS_Deer"; a path with no dot gets its last part again.
---game.Creatures:GetModel gives one of these for a creature.
---@class WaxModelLook
---@field mesh string The game path of a skeletal mesh.
---@field materials? table<integer, string> Game paths of materials to put on the mesh, by slot, 1 first.
---@field parts? WaxModelPart[] More meshes that move with the first: pieces on the same skeleton, or what the model wears.
---@field fur? WaxModelFur|WaxModelFur[]
---@field walk? string The game path of the animation "walk" plays.
---@field idle? string The game path of the animation "idle" plays.
---@field loop? string The game path of an animation for a model with no walk and no idle, such as flying.
---@field animation? "walk"|"idle"|"blueprint"|string|false What plays, in a loop. "walk" (the default) plays walk, or idle or loop when there is none. "idle" plays idle, or loop when there is no walk either. "blueprint" runs the mesh's own animation blueprint. A game path plays that animation. false stands still.
---@field blueprint? string The game path of the mesh's own animation blueprint. Only used with animation = "blueprint".
---@field speed? number What an animation blueprint is told the creature moves at: 0 stands, 150 (the default) walks. Only blueprints of the game's creature kind listen to it.
---@field facing? number The way the mesh faces as its creature's class turns it, in degrees. Default -90. The view starts in front of the model by it.
---@field scale? number How much larger the game draws the creature than its mesh. The view fits every model to its box, so it changes nothing there.
---@field walks? boolean True when there is a walk to play. game.Creatures:GetModel sets it; the view does not read it.
---@field against? WaxModelLook Another model to be seen beside, such as a young animal's adult. This one is then as much smaller in its box as it is smaller than that one in the game, by the two meshes' sizes and their scale. It never fills less than four tenths of the box, and a model larger than the other fills the box as it would alone. Only mesh and scale of the other are read.

---@class WaxModelOptions: WaxModelLook, WaxOptions
---@field mesh? string Nothing shows until Show is called when this is left out.
---@field width? number Default 240.
---@field height? number As tall as it is wide when left out.
---@field size? number The side of a square view, in place of width and height.
---@field align? "left"|"center"|"right" Where the view sits in its line. Default "center".
---@field backdrop? WaxColor|boolean A colour behind the model, or true for the theme's card colour. See-through when left out.
---@field spin? number|false Degrees a second it turns by itself until the player touches it. Default 12.
---@field turn? boolean False: the player cannot turn it.
---@field zoom? boolean False: the wheel is left to the page.
---@field reset? boolean False leaves out the small button that puts the view back.
---@field light? number How bright the three lights are: 1 as designed, up to 4. At 0 the model is a dark shape.
---@field yaw? number Where the view starts, in degrees round the model: 0 looks at its front, 90 at its right side. Default -40.
---@field pitch? number How many degrees above the model the view starts. Default 10. Kept between -20 and 75.
---@field distance? number How far away the view starts: 1 fits the model in the box. Default 1. Kept between 0.45 and 1.6.

---A creature or any other skeletal mesh of the game, drawn in 3D. It turns slowly by itself until the player touches it.
---The model follows the mouse when dragged: to the right its near side goes right, and down it is seen more from above.
---The wheel moves the camera nearer and further while the mouse is over the view, and the page does not scroll then.
---Two presses in a row put the view back. Nothing is drawn while the view is not on screen.
---@class WaxModel: WaxControl
---@field Loaded WaxSignal<fun()> The model given at the start or to Show is in the picture.
---@field Failed WaxSignal<fun(reason: string)> The mesh could not be loaded or is not a skeletal mesh, or the game could not make the view.
---@field Turned WaxSignal<fun(yaw: number, pitch: number, distance: number)> The player let go after a drag, turned the wheel or put the view back.
---@field Clicked WaxSignal<fun()> The player pressed the view and let go without turning it.
local Model = {}

---Shows another model in the same box. The view goes back to where it starts, unless the first mesh is the one that
---shows already: the same body with other parts or other fur is seen from where the player left it.
---@param look WaxModelLook
function Model:Show(look) end

---Empties the box.
function Model:Clear() end

---Where the camera is: degrees round the model (0 looks at its front, 90 at its right side), degrees above it (negative is below), and how far away (1 fits the model in the box).
---@return number yaw
---@return number pitch
---@return number distance
function Model:GetView() end

---Puts the camera somewhere. What is left out stays as it is. The slow turn stops.
---@param yaw? number
---@param pitch? number Kept between -20 and 75.
---@param distance? number Kept between 0.45 and 1.6.
function Model:SetView(yaw, pitch, distance) end

---Puts the view back where it started, and starts the slow turn again.
function Model:Reset() end

---Changes what plays: "walk", "idle", "blueprint", the game path of an animation, or false to stand still.
---@param animation "walk"|"idle"|"blueprint"|string|false
---@param speed? number For "blueprint": what the creature is said to move at. 0 stands, 150 walks.
function Model:SetAnimation(animation, speed) end

---Puts a shape from game.Assets:Mesh or game.Assets:Model on a socket or a bone of the model that shows: a tool in a
---hand, a hat on a head. The model has to be in the picture: wait for Loaded. It goes when another model is shown.
---@param shape WaxMesh
---@param options? { socket?: string, at?: table, turn?: table, scale?: number, material?: any }
function Model:Attach(shape, options) end

---Plays an animation from game.Animations:Define on the model that shows, so it can be looked at from every side
---before it is used in the world. The model has to be in the picture: wait for Loaded. Give the look `facing = 0`
---for a mesh that faces along its own X, as the player's body does.
---@param animation WaxAnimation
---@param options? WaxAnimationPlayOptions
---@return WaxAnimationPlay
function Model:Play(animation, options) end

---True once the model given at the start or to Show is in the picture.
---@return boolean
function Model:IsLoaded() end
