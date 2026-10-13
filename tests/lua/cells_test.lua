dofile("gmock.lua")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end

local function same(a, b) return a and b and math.abs(a.x - b.x) < 1e-6 and math.abs(a.y - b.y) < 1e-6 and math.abs(a.z - b.z) < 1e-6 end
local hooks = {}
hook = { Add = function(event, id, fn) hooks[event] = hooks[event] or {} hooks[event][id] = fn end }
concommand = { Add = function() end }
timer = { Simple = function(_, fn) fn() end }
function IsValid(x) return x ~= nil and x ~= false and (type(x) ~= "table" or x.valid ~= false) end
game = { GetMap = function() return "sgm_skate3_portcarverton" end }
local FILES = {}
file = {
	Read = function(path) return FILES[path] end,
	Exists = function(path) return FILES[path] ~= nil end,
	Open = function(path)
		local data = FILES[path]
		if not data then return nil end
		return { Size = function() return #data end, Read = function() return data end, Close = function() end }
	end,
}
util = util or {}
util.JSONToTable = function(s) return s == "index" and { phys = { dir = "phys", piece = 630, split = { ["4 -2"] = { "1" } } } } or nil end
FILES["skategm_stream/sgm_skate3_portcarverton/index.json"] = "index"

local function u32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
local function i32(v) if v < 0 then v = v + 4294967296 end return u32(v) end
local function u16(v) return string.char(v % 256, math.floor(v / 256)) end
local verts = { { 0, 0, 10 }, { 100, 0, 10 }, { 0, -50.5, 12 }, { 100, -50.5, 12 } }
local data = { "SGC1", u32(#verts), u32(2) }
for _, v in ipairs(verts) do for k = 1, 3 do data[#data + 1] = i32(math.floor(v[k] * 32 + 0.5)) end end
for _, i in ipairs({ 0, 1, 2, 1, 3, 2 }) do data[#data + 1] = u16(i) end
FILES["skategm_stream/sgm_skate3_portcarverton/phys/g3_-2.bin"] = table.concat(data)
FILES["skategm_stream/sgm_skate3_portcarverton/phys/g4_-2_1.bin"] = table.concat(data)

SERVER, CLIENT = true, false
dofile("../../addon/skategm/lua/skategm/sh_cells.lua")
local C = SKATEGM_CELLS

check("on when the map's index lists physics ground", C.On() == true and C.PIECE == 630)
local list, nf = C.ReadPiece(3, -2)
check("a piece decodes: 2 triangles, 6 corners", nf == 2 and #list == 6)
check("... positions at 1/32 unit, negatives kept", list[3].pos.y == -50.5 and list[5].pos.x == 100 and list[5].pos.z == 12)
check("... corners shared, not copied", list[2] == list[4])
check("a damaged piece is refused", C.DecodePiece("SGC1" .. u32(5) .. u32(9)) == nil and C.DecodePiece("nope") == nil)
check("a split piece's file name and corner", C.PieceFile(4, -2, "1") == "skategm_stream/sgm_skate3_portcarverton/phys/g4_-2_1.bin" and select(1, C.PieceCorner(4, -2, "1")) == 4 * 630 + 315 and select(2, C.PieceCorner(4, -2, "2")) == -2 * 630 + 315)
check("... split again: each digit a quarter of the last", select(1, C.PieceCorner(0, 0, "13")) == 315 + 157.5 and select(2, C.PieceCorner(0, 0, "13")) == 157.5)
check("a piece's parts: whole, split (from the index) or none", C.PieceParts(3, -2)[1] == "" and C.PieceParts(4, -2)[1] == "1" and #C.PieceParts(9, 9) == 0)
check("cell keys and snapping", C.Key(Vector(270336, -16384, 5)) == "33 -2" and same(C.Snap(Vector(4000, -4200, 7)), Vector(0, -8192, 0)))

local function Ent(cell, pos)
	local e = { valid = true, nw = cell and Vector(cell.x, cell.y, 0) or nil, pos = pos or Vector(0, 0, 0) }
	function e:GetNW2Vector(_, d) return self.nw or d end
	function e:SetNW2Vector(_, v) self.nw = v end
	function e:GetPos() return self.pos end
	function e:SetPos(p) self.pos = p end
	function e:GetParent() return self.parent end
	function e:SetCustomCollisionCheck(on) self.custom = on end
	function e:CollisionRulesChanged() self.rules = (self.rules or 0) + 1 end
	return e
end
local collide = hooks.ShouldCollide.skategm_cells
local a, b = Ent(), Ent()
a.SkateGMCell, b.SkateGMCell = "0 0", "1 0"
check("things in different cells never touch", collide(a, b) == false)
b.SkateGMCell = "0 0"
check("... in the same cell they do (the game decides)", collide(a, b) == nil)
b.SkateGMCell = nil
check("... nor is an unplaced thing kept apart", collide(a, b) == nil)

local parent = Ent(Vector(8192, 0, 0))
local child = Ent()
child.parent = parent
check("a child is in its parent's cell", same(C.CellOf(child), Vector(8192, 0, 0)))
check("absolute position = cell + Source position", same(SkateGMEntAbs(Ent(Vector(-8192, 8192, 0), Vector(10, 20, 30))), Vector(-8182, 8212, 30)))

local players = {}
player = { GetAll = function() return players end }
local ply = Ent(Vector(270336, -16384, 0), Vector(100, 0, 50))
players[1] = ply
ents = { Create = function() return Ent() end }
constraint = nil
CurTime, SysTime = function() return 0 end, os.clock
dofile("../../addon/skategm/lua/skategm/sv_cells.lua")
local cell = C.CellFor(Vector(270336 + 500, -16384 - 300, 10))
check("a thing placed near a player joins their cell", same(cell, Vector(270336, -16384, 0)))
check("... far from everyone, the nearest cell", same(C.CellFor(Vector(-100000, 3, 0)), Vector(-98304, 0, 0)))
local prop = Ent()
function prop:GetClass() return "prop_physics" end
function prop:IsPlayer() return false end
function prop:IsWorld() return false end
function prop:EntIndex() return 5 end
function prop:CreatedByMap() return false end
function prop:GetModel() return "models/a.mdl" end
function prop:GetPhysicsObject() return nil end
SkateGMPlace(prop, Vector(270336 + 500, -16384 - 300, 10))
check("placing: Source position in its cell, cell recorded", same(prop.pos, Vector(500, -300, 10)) and same(prop.nw, Vector(270336, -16384, 0)) and prop.SkateGMCell == "33 -2")
check("... collision rules told about it", prop.custom == true and (prop.rules or 0) >= 1)
check("... and tracked", C.tracked[prop] == true)
C.MoveGroup(prop, Vector(270336 + 8192, -16384, 0))
check("moving a thing to the next cell keeps where it really is", same(SkateGMEntAbs(prop), Vector(270336 + 500, -16384 - 300, 10)) and prop.SkateGMCell == "34 -2")
check("SkateGMToLocal gives a point in the thing's cell", same(SkateGMToLocal(prop, Vector(270336 + 8192 + 7, -16384, 0)), Vector(7, 0, 0)))
local other = Ent()
other.SkateGMCell = "0 0"
check("tools and pickups don't reach across cells", C.Apart(prop, other) == true and hooks.PhysgunPickup.skategm_cells(other, prop) == false)

local quad = { "SGC1", u32(4), u32(2) }
for _, v in ipairs({ { 10, 10, 11.6 }, { 600, 10, 11.6 }, { 10, 600, 11.6 }, { 600, 600, 11.6 } }) do for k = 1, 3 do quad[#quad + 1] = i32(math.floor(v[k] * 32 + 0.5)) end end
for _, i in ipairs({ 0, 1, 2, 1, 3, 2 }) do quad[#quad + 1] = u16(i) end
FILES["skategm_stream/sgm_skate3_portcarverton/phys/g5_5.bin"] = table.concat(quad)
C.whole = {}
local cx, cy = 5 * 630 + 300, 5 * 630 + 300
local f, pos, n = C.TraceAbs(Vector(cx, cy, 500), Vector(cx, cy, -500))
check("a trace down finds the map's own ground (the physics pieces)", f and math.abs(pos.z - 11.6) < 0.5 and n.z > 0.9)
local f2 = C.TraceAbs(Vector(cx, cy, -500), Vector(cx, cy, 500))
local _, _, n2 = C.TraceAbs(Vector(cx, cy, -500), Vector(cx, cy, 500))
check("... from below too, the normal facing the trace", f2 and n2.z < -0.9)
check("... and nothing where there's no ground", C.TraceAbs(Vector(-5000, 9000, 500), Vector(-5000, 9000, -500)) == nil)
local fd = C.TraceAbs(Vector(5 * 630 - 400, cy, 400), Vector(cx, cy, -100))
check("a slanted ray through several pieces finds it", fd and math.abs(select(2, C.TraceAbs(Vector(5 * 630 - 400, cy, 400), Vector(cx, cy, -100))).z - 11.6) < 0.01)
util.TraceLine = function(t) return { Hit = false, Fraction = 1, HitPos = t.endpos } end
game.GetWorld = function() return "world" end
local tr = SkateGMTraceWorld({ start = Vector(cx, cy, 500), endpos = Vector(cx, cy, -500) })
check("SkateGMTraceWorld: a hit like util.TraceLine's (server: absolute positions)", tr.Hit and tr.HitWorld and math.abs(tr.HitPos.z - 11.6) < 0.5 and tr.Fraction > 0.4 and tr.Fraction < 0.6)
local tr2 = SkateGMTraceWorld({ start = Vector(300, 300, 500), endpos = Vector(300, 300, -500) }, Vector(5 * 630, 5 * 630, 0))
check("... or an entity's own cell", tr2.Hit and math.abs(tr2.HitPos.z - 11.6) < 0.5 and math.abs(tr2.HitPos.x - 300) < 1e-6)
check("util.TraceLine on streamed maps: solid masks see the map's ground, water ones don't", C.WantsWorld({ mask = MASK_SOLID or 33570827 }) and not C.WantsWorld({ mask = 32 }))
SERVER, CLIENT = true, false
local ent = Ent(Vector(8192, 0, 0))
function ent:IsValid() return true end
IsEntity = function(x) return type(x) == "table" and x.GetNW2Vector ~= nil end
check("... a server trace runs in the cell of the entity it filters (an eye trace: the player's)", same(C.FrameFor({ filter = ent }), Vector(8192, 0, 0)) and C.FrameFor({}) == nil)
local tf = C.TraceAbs(Vector(5 * 630 + 300, 5 * 630 + 300, 30000), Vector(5 * 630 + 300, 5 * 630 + 300, 20000))
check("a ray far above the ground skips its pieces (and finds nothing)", tf == nil)
