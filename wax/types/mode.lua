---@meta _

---How this copy of the game runs, game.Mode. It is read when Wax starts and again when the map changes.
---@class WaxMode
---@field kind "server"|"host"|"client"|"single" "server": a dedicated server, with no screen and nobody at the keyboard. "host": a player hosting a world from the game. "client": joined someone else's world. "single": alone.
---@field IsServer boolean True on a dedicated server.
---@field IsAuthority boolean True where the session's rules run: a dedicated server, a host, or alone. False for a client.
---@field HasScreen boolean False on a dedicated server, where there is no interface: `ui` is nil there, and nothing of a mod can be shown or pressed. True in a game, from its first frame.
---@field Changed WaxSignal<fun(kind: string, before: string)> Fires after a map change when the kind is not what it was, with the new kind and the one before.
local Mode = {}
