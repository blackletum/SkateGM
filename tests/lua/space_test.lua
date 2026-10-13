dofile("gmock.lua")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end
local function near(a, b, eps) return a and b and math.abs(a.x - b.x) < (eps or 1e-6) and math.abs(a.y - b.y) < (eps or 1e-6) and math.abs(a.z - b.z) < (eps or 1e-6) end

local hooks = {}
hook = { Add = function(event, id, fn) hooks[event] = hooks[event] or {} hooks[event][id] = fn end }
concommand = { Add = function() end }
timer = { Simple = function(_, fn) fn() end }
function IsValid(x) return x ~= nil and x ~= false and (type(x) ~= "table" or x.valid ~= false) end
IsEntity = function(x) return type(x) == "table" and x.GetNW2Vector ~= nil end
local MAP = "gm_flat"
game = { GetMap = function() return MAP end, GetWorld = function() return "world" end }
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
util.JSONToTable = function(s) return s == "index" and { phys = { dir = "phys", piece = 630 } } or nil end
CurTime, SysTime = function() return 0 end, os.clock

local all = {}
local function Ent(pos, cell, size)
	local e = { valid = true, pos = pos or Vector(0, 0, 0), nw = cell, size = size, class = "prop_physics" }
	function e:GetPos() return self.pos end
	function e:SetPos(p) self.pos = p end
	function e:SetAngles(a) self.ang = a end
	function e:GetNW2Vector(_, d) return self.nw or d end
	function e:SetNW2Vector(_, v) self.nw = v end
	function e:GetParent() return self.parent end
	function e:IsPlayer() return self.player == true end
	function e:IsWorld() return false end
	function e:GetClass() return self.class end
	function e:SetCustomCollisionCheck(on) self.custom = on end
	function e:CollisionRulesChanged() end
	function e:EntIndex() return 7 end
	function e:CreatedByMap() return false end
	function e:GetModel() return "models/box.mdl" end
	function e:GetPhysicsObject() return nil end
	if size then all[#all + 1] = e end
	return e
end

-- the engine's trace, in Source positions: boxes wherever their entities sit,
-- whatever cell they're in (traces ignore ShouldCollide)
local traces = 0
local function Skip(filter, e)
	if filter == nil then return false end
	if type(filter) == "function" then return not filter(e) end
	if filter == e then return true end
	if type(filter) == "table" and not IsEntity(filter) then for _, f in pairs(filter) do if f == e then return true end end end
	return false
end
local function EngineTrace(t)
	traces = traces + 1
	local a, b = t.start, t.endpos
	local d = b - a
	local best, bestE, bestN
	for _, e in ipairs(all) do
		if not Skip(t.filter, e) then
			local t0, t1, n = 0, 1, nil
			local ok = true
			for _, ax in ipairs({ "x", "y", "z" }) do
				local lo, hi = e.pos[ax] - e.size, e.pos[ax] + e.size
				if math.abs(d[ax]) < 1e-9 then
					if a[ax] < lo or a[ax] > hi then ok = false end
				else
					local u0, u1 = (lo - a[ax]) / d[ax], (hi - a[ax]) / d[ax]
					local side = d[ax] > 0 and -1 or 1
					if u0 > u1 then u0, u1 = u1, u0 end
					if u0 > t0 then t0, n = u0, Vector(ax == "x" and side or 0, ax == "y" and side or 0, ax == "z" and side or 0) end
					if u1 < t1 then t1 = u1 end
				end
			end
			if ok and t0 <= t1 and (not best or t0 < best) then best, bestE, bestN = t0, e, n or Vector(0, 0, 1) end
		end
	end
	if not best then return { Hit = false, Fraction = 1, HitPos = b, StartPos = a } end
	return { Hit = true, Fraction = best, HitPos = a + d * best, HitNormal = bestN, Entity = bestE, StartPos = a, HitNonWorld = true }
end
util.TraceLine = EngineTrace

local SPACE = SKATEGM_SPACE
SPACE.FRAMES_FOR = 0
SERVER, CLIENT = true, false

-- a normal map: nothing moves
local plain = Ent(Vector(10, 20, 30), Vector(8192, 0, 0))
check("normal map: not streamed", SPACE.Streamed() == false)
check("... an entity's absolute position is its Source position", near(SPACE.Abs(plain), Vector(10, 20, 30)) and near(SPACE.ToLocal(plain, Vector(1, 2, 3)), Vector(1, 2, 3)))
check("... its frame is zero, whatever its NW2 says", near(SPACE.FrameOf(plain), Vector(0, 0, 0)))
local asked
ents = { FindInSphere = function(p, r) asked = p return { plain } end }
check("... FindInSphere is the engine's", SPACE.FindInSphere(Vector(5, 6, 7), 10)[1] == plain and near(asked, Vector(5, 6, 7)))
local before = traces
local tr = SPACE.Trace({ start = Vector(0, 0, 0), endpos = Vector(1, 0, 0) })
check("... Trace is util.TraceLine, once", traces == before + 1 and tr.Hit == false)
SPACE.Place(plain, Vector(50000, 1, 2))
check("... Place puts it where asked", near(plain.pos, Vector(50000, 1, 2)))

-- a streamed map, cells of 8192, the map's own ground in pieces of 630
MAP = "sgm_skate3_portcarverton"
FILES["skategm_stream/" .. MAP .. "/index.json"] = "index"
local function u32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
local function i32(v) if v < 0 then v = v + 4294967296 end return u32(v) end
local function u16(v) return string.char(v % 256, math.floor(v / 256)) end
local quad = { "SGC1", u32(4), u32(2) }
for _, v in ipairs({ { 10, 10, 11.6 }, { 600, 10, 11.6 }, { 10, 600, 11.6 }, { 600, 600, 11.6 } }) do for k = 1, 3 do quad[#quad + 1] = i32(math.floor(v[k] * 32 + 0.5)) end end
for _, i in ipairs({ 0, 1, 2, 1, 3, 2 }) do quad[#quad + 1] = u16(i) end
FILES["skategm_stream/" .. MAP .. "/phys/g5_5.bin"] = table.concat(quad)

local ply = Ent(Vector(100, 0, 0), Vector(0, 0, 0))
ply.player = true
local players = { ply }
player = { GetAll = function() return players end }
constraint = nil
ents = { Create = function() return Ent() end, FindInSphere = function(p, r)
	local out = {}
	for _, e in ipairs(all) do if (e.pos - p):Length() <= r then out[#out + 1] = e end end
	return out
end }
dofile("../../addon/skategm/lua/skategm/sh_cells.lua")
dofile("../../addon/skategm/lua/skategm/sv_cells.lua")
local C = SKATEGM_CELLS

check("streamed map: streamed, cells on", SPACE.Streamed() and C.On())
local e = Ent(Vector(10, 20, 30), Vector(-8192, 8192, 0))
check("Abs = cell + Source position", near(SPACE.Abs(e), Vector(-8182, 8212, 30)))
check("... ToLocal undoes it", near(SPACE.ToLocal(e, SPACE.Abs(e)), e.pos) and near(SPACE.FromLocal(e, Vector(1, 1, 1)), Vector(-8191, 8193, 1)))
local child = Ent(Vector(0, 0, 0))
child.parent = e
check("... a child is in its parent's frame", near(SPACE.FrameOf(child), Vector(-8192, 8192, 0)))
check("the old names agree", near(SkateGMEntAbs(e), SPACE.Abs(e)) and near(SkateGMToLocal(e, Vector(0, 0, 0)), Vector(8192, -8192, 0)) and near(SkateGMFrame(e), Vector(-8192, 8192, 0)) and SkateGMStreamed())

SPACE.Place(ply, Vector(5000, 0, 0))
check("Place: a player within 0.75 of a cell keeps it", near(ply.nw, Vector(0, 0, 0)) and near(ply.pos, Vector(5000, 0, 0)))
SPACE.Place(ply, Vector(7000, -300, 5))
check("... past it, into the next cell (and told so)", near(ply.nw, Vector(8192, 0, 0)) and ply.SkateGMCell == "1 0" and near(ply.pos, Vector(-1192, -300, 5)))
check("... where it really is is kept", near(SPACE.Abs(ply), Vector(7000, -300, 5)) and near(SkateGMAbsPos(ply), Vector(7000, -300, 5)))
check("SkateGMLocal: the same cell rule", near(SkateGMLocal(ply, Vector(8000, 0, 0)), Vector(-192, 0, 0)) and near(ply.nw, Vector(8192, 0, 0)))
SPACE.Place(ply, Vector(100, 0, 0))
check("... and back", near(ply.nw, Vector(0, 0, 0)) and near(ply.pos, Vector(100, 0, 0)))

-- three boxes at the same Source spot, in three cells
local A = Ent(nil, nil, 16)
SPACE.Place(A, Vector(8092, 0, 50))
local B = Ent(nil, nil, 16)
SPACE.Place(B, Vector(81920 - 100, 0, 50))
local D = Ent(nil, nil, 16)
SPACE.Place(D, Vector(-100, 0, 50))
check("Place: a thing far from everyone goes in the cell under it", near(A.nw, Vector(8192, 0, 0)) and near(A.pos, Vector(-100, 0, 50)) and C.tracked[A])
check("... near a player, in the player's cell", near(D.nw, Vector(0, 0, 0)) and near(D.pos, Vector(-100, 0, 50)))
check("... (all three at one Source spot)", near(A.pos, B.pos) and near(B.pos, D.pos))

local found = SPACE.FindInSphere(Vector(8000, 0, 50), 120)
check("FindInSphere: the thing in the next cell", #found == 1 and found[1] == A)
local found2 = SPACE.FindInSphere(Vector(-60, 0, 50), 100)
check("... not the ones at the same Source spot of other cells", #found2 == 1 and found2[1] == D)
check("... nothing where nothing is", #SPACE.FindInSphere(Vector(40000, 0, 50), 100) == 0)

before = traces
tr = SPACE.Trace({ start = Vector(3000, 0, 50), endpos = Vector(9000, 0, 50) })
check("Trace: crosses into the next cell and hits the thing there", tr.Hit and tr.Entity == A)
check("... HitPos absolute, Fraction of the whole ray", near(tr.HitPos, Vector(8076, 0, 50), 1e-4) and math.abs(tr.Fraction - (8076 - 3000) / 6000) < 1e-6 and near(tr.StartPos, Vector(3000, 0, 50)))
check("... the engine's trace ran", traces > before)
tr = SPACE.Trace({ start = Vector(3000, 0, 50), endpos = Vector(9000, 0, 50), filter = A })
check("... its filter honoured (then nothing)", not tr.Hit and near(tr.HitPos, Vector(9000, 0, 50)))
tr = SPACE.Trace({ start = Vector(3000, 0, 50), endpos = Vector(-1000, 0, 50) })
check("... the other way, the one in my cell", tr.Hit and tr.Entity == D and near(tr.HitPos, Vector(-84, 0, 50), 1e-4))

local cx, cy = 5 * 630 + 300, 5 * 630 + 300
before = traces
tr = SPACE.Trace({ start = Vector(cx, cy, 500), endpos = Vector(cx, cy, -500) })
check("Trace: the map's own ground (the stream mesh)", tr.Hit and tr.HitWorld and math.abs(tr.HitPos.z - 11.6) < 0.01 and tr.HitNormal.z > 0.9)
check("... after the engine's trace (never skipped)", traces > before)
before = traces
tr = SkateGMTraceWorld({ start = Vector(8092, 0, 500), endpos = Vector(8092, 0, -500) })
check("SkateGMTraceWorld on the server: absolute, things in cells hit", traces > before and tr.Hit and tr.Entity == A and math.abs(tr.HitPos.z - 66) < 1e-4)
tr = SkateGMTraceWorld({ start = Vector(-100, 0, 500), endpos = Vector(-100, 0, -500) }, Vector(8192, 0, 0))
check("... or relative to a frame given", tr.Hit and tr.Entity == A and near(tr.HitPos, Vector(-100, 0, 66), 1e-4))

local ply2 = Ent(Vector(0, 0, 0), Vector(81920, 0, 0))
ply2.player = true
players[2] = ply2
tr = util.TraceLine({ start = Vector(-100, 0, 500), endpos = Vector(-100, 0, -500), filter = ply2 })
check("util.TraceLine: local in, local out, in the filter entity's cell", tr.Hit and tr.Entity == B and near(tr.HitPos, Vector(-100, 0, 66), 1e-4))
tr = util.TraceLine({ start = Vector(cx, cy, 500), endpos = Vector(cx, cy, -500), filter = ply })
check("... with the map's ground", tr.Hit and math.abs(tr.HitPos.z - 11.6) < 0.01)
local out = {}
util.TraceLine({ start = Vector(cx, cy, 500), endpos = Vector(cx, cy, -500), filter = ply, output = out })
check("... into output too", out.Hit and math.abs(out.HitPos.z - 11.6) < 0.01)
players[2] = nil

local z, ok = SPACE.Ground(Vector(8092, 0, 90))
check("Ground: on top of a thing in another cell", ok and math.abs(z - 66) < 1e-4)
z, ok = SPACE.Ground(Vector(cx, cy, 40))
check("... on the map's ground", ok and math.abs(z - 11.6) < 0.01)
z, ok = SPACE.Ground(Vector(-30000, 5000, 40))
check("... under nothing: the height asked about", not ok and z == 40)

-- a streamed map's client: my frame is my cell
SERVER, CLIENT = false, true
local me = Ent(Vector(0, 0, 0), Vector(8192, 0, 0))
LocalPlayer = function() return me end
SkateGM = {}
check("client: the view frame is my cell", near(SPACE.ViewFrame(), Vector(8192, 0, 0)))
check("... a thing in my cell where it is, one in another shifted", near(SPACE.View(A), Vector(-100, 0, 50)) and near(SPACE.View(D), Vector(-8292, 0, 50)))
check("... FromView / ToView", near(SPACE.FromView(Vector(1, 0, 0)), Vector(8193, 0, 0)) and near(SPACE.ToView(Vector(8193, 0, 0)), Vector(1, 0, 0)))
tr = SkateGMTraceWorld({ start = Vector(-8292, 0, 500), endpos = Vector(-8292, 0, -500) })
check("... SkateGMTraceWorld in my view: the other cell's thing, in my view", tr.Hit and tr.Entity == D and near(tr.HitPos, Vector(-8292, 0, 66), 1e-4))

-- the original InfMap, client: everything relative to my chunk
MAP = "gm_infmap_test"
local chunk = Vector(32768, 0, 1000)
SkateGM = { frameOffset = function() return chunk end }
local thing = Ent(Vector(100, 0, 0))
check("InfMap1 client: not streamed, frame = my chunk", not SPACE.Streamed() and near(SPACE.FrameOf(thing), chunk))
check("... Abs adds it, ToLocal takes it off, View is Source", near(SPACE.Abs(thing), Vector(32868, 0, 1000)) and near(SPACE.ToLocal(thing, Vector(32868, 0, 1000)), Vector(100, 0, 0)) and near(SPACE.View(thing), Vector(100, 0, 0)))
local at
ents.FindInSphere = function(p) at = p return { thing } end
SPACE.FindInSphere(Vector(32868, 0, 1000), 50)
check("... FindInSphere asks the engine locally", near(at, Vector(100, 0, 0)))
local seen
util.TraceLine = function(t) seen = t.start return { Hit = true, Fraction = 0.5, HitPos = (t.start + t.endpos) / 2 } end
tr = SPACE.Trace({ start = Vector(32768, 0, 1100), endpos = Vector(32768, 0, 900) })
check("... Trace: local to the engine, absolute back", near(seen, Vector(0, 0, 100)) and near(tr.HitPos, Vector(32768, 0, 1000)))
tr = SkateGMTraceWorld({ start = Vector(0, 0, 100), endpos = Vector(0, 0, -100) })
check("... SkateGMTraceWorld keeps the view frame (unchanged on InfMap)", near(seen, Vector(0, 0, 100)) and near(tr.HitPos, Vector(0, 0, 0)))
