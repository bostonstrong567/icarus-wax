---@meta _

---A colour for a material or a mesh: a name ("Red", "Orange", "Yellow", "Green", "Cyan", "Blue", "Purple", "Magenta",
---"Pink", "White", "Grey", "Black"), "#rrggbb" or "#rrggbbaa", or a table of values from 0 to 1, written
---{ R = 1, G = 0.5, B = 0 } or { 1, 0.5, 0 }, with A or a fourth value for the alpha (1 when omitted).
---@alias WaxAssetColor string|{ R: number, G: number, B: number, A?: number, linear?: boolean }|number[]

---What game.Assets:Material sets on the new material. Each table goes by the parameter names of the material it
---starts from. A name that material does not have changes nothing, and no error says so.
---@class WaxMaterialOptions
---@field colors? table<string, WaxAssetColor> Colour parameters. A colour is taken as it looks on the screen and turned into the linear values a material works with. A table with linear = true goes on as it is, and may then hold values above 1, which is how a glowing material is made brighter.
---@field numbers? table<string, number> Number parameters.
---@field textures? table<string, Texture|string> Texture parameters: a texture from Load or Texture, or the path of one, which is then loaded and kept as Load does.

---What game.Assets:Mesh makes a shape from. Give box, or vertices and triangles.
---@class WaxMeshShape
---@field vertices? ({ X: number, Y: number, Z: number }|number[])[] The corners, at least 3 and at most 65,000, each { X = 0, Y = 0, Z = 0 } or { 0, 0, 0 }. 100 is one metre, measured from the part's own place.
---@field triangles? integer[] Three vertex numbers for each triangle, counted from 1. A triangle is seen from the side on which its corners run counter-clockwise.
---@field box? number|{ X: number, Y: number, Z: number } A box around the part's place in the stead of vertices and triangles: the length of its sides, or one length for each direction. It has 24 vertices, four a side, so each side is flat and takes a whole picture.
---@field normals? ({ X: number, Y: number, Z: number }|number[])[] The direction each vertex faces, one for each vertex. When omitted they are worked out from the triangles: a vertex that several triangles share faces between them, which shades a corner round. Give a side its own vertices to keep it flat.
---@field uvs? ({ X: number, Y: number }|number[])[] Where each vertex is on a picture, one for each vertex: { X = 0, Y = 0 } or { 0, 0 }, from 0 to 1 across the picture. When omitted the shape has none, and a box has its own.
---@field colors? WaxAssetColor[] A colour for each vertex, for materials that read it. The values go on as given, without the change to linear values that a material's colours get.
---@field collision? boolean True makes things stop at the shape. False when omitted.

---What mesh:Apply takes besides the part.
---@class WaxMeshApplyOptions
---@field section? integer Which section of the part the shape becomes, from 0 to 15. 0 when omitted. A part draws all its sections, each with its own material.
---@field material? MaterialInterface The material the section is drawn with: one from Material or Load. When omitted the section keeps the material the part has for it, which at first is the engine's default one.
---@field collision? boolean Whether things stop at the shape here. The shape's own answer when omitted.

---A shape made of numbers, as game.Assets:Mesh gives it. It is plain Lua and holds nothing of the game, so it can be
---kept for as long as you like and put on any number of parts. Its fields cannot be changed: make another mesh.
---@class WaxMesh
---@field VertexCount integer How many vertices it has.
---@field TriangleCount integer How many triangles it has.
---@field Size { X: number, Y: number, Z: number } How far its vertices reach in each direction.
local Mesh = {}

---Puts the shape on a part as one of its sections, in place of what that section had. The part is an Instance of a
---ProceduralMeshComponent on an actor. When the mod that called this unloads, the section is cleared again if the
---part still exists.
---
---Every vertex is handed to the game one at a time. A box took 0.2 ms, with or without collision, and 3.7 ms the
---first time a shape with collision was put on in a session. So put a shape on once and keep it, not every frame.
---A character stands on a shape that has collision.
---@param part ProceduralMeshComponent
---@param options? WaxMeshApplyOptions
function Mesh:Apply(part, options) end

---The game's assets by path, pictures from a mod's own files, materials made from the game's, and shapes made of
---numbers. What Load, Texture and Material give is kept in memory for the mod that asked: the game frees an asset
---nothing uses within minutes, and using it after that crashes. When the mod unloads, everything it asked for is let
---go. Nothing here runs between calls, so it costs nothing a frame.
---
---While Wax's interface is not running nothing can be kept. The log says so once, and what you get may then be freed
---within minutes: ask for it again right before each use.
---@class WaxAssets
local Assets = {}

---Loads an asset of the game by its path and keeps it in memory for your mod. The path is "/Game/Folder/Name" or
---"/Game/Folder/Name.Name", also in the form the editor copies, Texture2D'/Game/Folder/Name.Name'. A blueprint's class
---is asked for as "/Game/Folder/BP_Thing.BP_Thing_C". Letter case does not matter.
---
---Gives nil and the reason when the text is not a path or the game has no such asset. The reason names the asset in
---that file or the nearest names in that folder when the game's own list of assets has any. A path that gave nothing is
---not tried again for 5 seconds.
---
---Asked again, the same Instance comes back for about 0.02 ms. A first load stops the game until it is done: an item
---picture took 0.2 to 1 ms, a mesh 5 ms, and a path that gives nothing 0.2 to 5 ms the first time. So load when your
---mod starts or a window opens, not in the middle of a fight.
---
---After a map change an Instance from before answers with an error: call Load again, which costs little because the
---asset is still kept. A class under "/Script/" is found too and is not kept, because the game never frees one.
---@param path string
---@return WaxInstance? asset
---@return string? why
function Assets:Load(path) end

---True while the asset at this path is in memory. It loads nothing and takes about 0.02 ms. For text that is not a
---path it gives false and the reason.
---@param path string
---@return boolean loaded
---@return string? why
function Assets:IsLoaded(path) end

---A picture file as a texture, kept for your mod. The file is a .png or .jpg in your mod's folder, named from that
---folder ("logo.png", "pictures/logo.png"), or a whole path. Asked again, the same texture comes back and no file is
---read. A small picture took about half a millisecond. The first JPG of a session took 3.7 ms.
---
---It raises an error when the file is not there, is not a PNG or JPG picture, or leaves the mod's folder with "..",
---and for a bare file name while no mod is running. A file that changed on disk is read again once everything that asked
---for it has let it go, which reloading your mod does when no other mod uses the file.
---@param file string
---@return Texture2D
function Assets:Texture(file) end

---A material of your own, made from one of the game's, with colours, numbers and textures set on it, kept for your
---mod. `parent` is a material from Load or its path. A material that Material itself made cannot be the parent: start
---from the one it was made from. Every call makes a new material (0.2 to 0.7 ms), so make it once and keep it.
---
---The options are read through before anything is made, so a mistake in them raises an error and leaves nothing behind:
---a parent or a texture the call itself loaded by path is let go again.
---A material does not outlive the map: it is let go when the map changes, so make it again after game.MapChanged.
---@param parent MaterialInterface|string
---@param options? WaxMaterialOptions
---@return MaterialInstanceDynamic
function Assets:Material(parent, options) end

---A shape made of numbers, checked through: a box, or your own vertices and triangles. Nothing is asked of the game
---until the mesh is put on a part with mesh:Apply. A mistake in the shape raises an error that names the entry.
---@param shape WaxMeshShape
---@return WaxMesh
function Assets:Mesh(shape) end

---What game.Assets:Model takes besides the file.
---@class WaxModelFileOptions
---@field scale? number How much larger the model is made. 100 when omitted, which fits a model made in metres: the game counts in centimetres.
---@field up? "y"|"z" Which way is up in the file. "y" when omitted, as most programs save an .obj. "z" for a file saved with Z up.
---@field flip? boolean True turns every triangle round. For a model that shows inside out.
---@field collision? boolean True makes things stop at the shape. False when omitted.

---Reads a 3D model from an .obj file in your mod's folder and gives it as a shape, the same kind game.Assets:Mesh
---gives: put it on a part with Apply, or name it as the mesh of a blueprint's part. No Unreal editor is needed. The
---file holds the shape only: give the part a material for its look. At most 65,000 vertices and 16 MB.
---@param file string The file's name inside the mod's folder, such as "models/rock.obj", or a whole path.
---@param options? WaxModelFileOptions
---@return WaxMesh
function Assets:Model(file, options) end

---Lets go of something your mod asked for, before the mod unloads: the Instance that Load, Texture or Material gave, or
---the path or file name it was asked for with. True when your mod held it. Once no mod holds it any more its Instance
---answers with an error, also for other code that had the same Instance, and the game frees it when nothing else uses
---it. To use it again, ask for it again.
---@param what WaxInstance|string
---@return boolean released
function Assets:Release(what) end
