---@meta _

---What game.Creatures:GetModel gives for a creature: its mesh, its fur, its other pieces and its animations, read from
---the game's own files when Wax was made. Give it to Container:Model or to a Model's Show as it is.
---@class WaxCreatureModel : WaxModelLook
---@field walks boolean True when the creature has a walk to play. Without one "walk" plays its idle, or what it does in the air.
---@field facing number The way the mesh faces as the creature's class turns it, in degrees.

---What GetModel can add to a creature's model.
---@class WaxCreatureModelOptions
---@field saddle? string A saddle the mount wears in the picture: the row of its item ("Saddle_Standard"), its tag ("Item.Mount.Saddle.Standard") or its own row in the game's saddle table ("Saddle_Horse_Standard"). The saddle is added to the model's parts as the game's table describes it for that mount: its mesh, its other material, the blueprint it follows the mount by and the socket it sits on. Where the game hides the mount's fur under that saddle, the fur gets the same mask. The second saddle the game shows under a cart is not added.

---One thing a mount can wear in its saddle slot, as game.Creatures:GetSaddles lists it.
---@class WaxSaddle
---@field Row string The saddle's row in the game's saddle table, such as "Saddle_Horse_Standard". Each mount has its own row for a saddle.
---@field Tag? string The tag an item carries to be this saddle, such as "Item.Mount.Saddle.Standard".
---@field Items string[] The rows of the items that carry the tag, such as "Saddle_Standard". Empty when the game has no such item.
