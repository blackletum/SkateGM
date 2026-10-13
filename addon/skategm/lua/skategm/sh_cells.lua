if not SKATEGM_SPACE then include("skategm/sh_space.lua") end
SKATEGM_CELLS = SKATEGM_CELLS or {}
local C = SKATEGM_CELLS
local SPACE = SKATEGM_SPACE
C.CELL = 8192
C.PIECE = 1260
C.DIR = "skategm_stream/"
C.GROUND = "skategm_ground"

local byte = string.byte

function C.On()
	if C.on == nil then
		if not SPACE.Streamed() then return false end
		if not (game and game.GetMap and file and file.Read and util and util.JSONToTable) then return false end
		local txt = file.Read(C.DIR .. game.GetMap() .. "/index.json", "GAME")
		local index = txt and util.JSONToTable(txt)
		local phys = index and index.phys
		C.on = phys ~= nil and tonumber(phys.piece) ~= nil
		if C.on then
			C.PIECE = tonumber(phys.piece)
			C.PHYS = C.DIR .. game.GetMap() .. "/" .. (phys.dir or "phys") .. "/"
			C.split = type(phys.split) == "table" and phys.split or {}
		end
	end
	return C.on
end

function C.Key(v) return math.Round(v.x / C.CELL) .. " " .. math.Round(v.y / C.CELL) end

C.CellOf = SPACE.CellOf
C.Abs = SPACE.Abs
C.Snap = SPACE.Snap

function C.PieceRange(lo, hi)
	local P = C.PIECE
	return math.floor(lo.x / P), math.floor(lo.y / P), math.floor(hi.x / P), math.floor(hi.y / P)
end

local function U32(s, at)
	local a, b, c, d = byte(s, at, at + 3)
	return a + b * 256 + c * 65536 + d * 16777216
end

local function I32(a, b, c, d)
	local v = a + b * 256 + c * 65536 + d * 16777216
	if d >= 128 then v = v - 4294967296 end
	return v
end

function C.PieceFile(ix, iy, sub)
	return C.PHYS .. "g" .. ix .. "_" .. iy .. ((sub and sub ~= "") and ("_" .. sub) or "") .. ".bin"
end

function C.PieceCorner(ix, iy, sub)
	local x, y, size = ix * C.PIECE, iy * C.PIECE, C.PIECE
	for i = 1, #(sub or "") do
		local q = tonumber(sub:sub(i, i)) or 0
		size = size / 2
		x = x + (q % 2) * size
		y = y + math.floor(q / 2) * size
	end
	return x, y
end

function C.PieceParts(ix, iy)
	local key = ix .. " " .. iy
	local split = C.split and C.split[key]
	if split then return split end
	C.whole = C.whole or {}
	local w = C.whole[key]
	if w == nil then
		w = file.Exists(C.PieceFile(ix, iy), "GAME") and { "" } or {}
		C.whole[key] = w
	end
	return w
end

function C.ReadPiece(ix, iy, sub)
	if not C.On() then return nil end
	local f = file.Open(C.PieceFile(ix, iy, sub), "rb", "GAME")
	if not f then return nil end
	local data = f:Read(f:Size())
	f:Close()
	return C.DecodePiece(data)
end

function C.DecodePiece(data)
	if not data or #data < 12 or data:sub(1, 4) ~= "SGC1" then return nil end
	local nv, nf = U32(data, 5), U32(data, 9)
	if #data < 12 + nv * 12 + nf * 6 then return nil end
	local verts = {}
	local at = 13
	for i = 1, nv do
		local a1, b1, c1, d1, a2, b2, c2, d2, a3, b3, c3, d3 = byte(data, at, at + 11)
		verts[i] = { pos = Vector(I32(a1, b1, c1, d1) / 32, I32(a2, b2, c2, d2) / 32, I32(a3, b3, c3, d3) / 32) }
		at = at + 12
	end
	local list = {}
	for i = 1, nf * 3 do
		local lo, hi = byte(data, at, at + 1)
		list[i] = verts[lo + hi * 256 + 1]
		at = at + 2
	end
	return list, nf
end

C.traceCache, C.traceOrder = C.traceCache or {}, C.traceOrder or {}
C.TRACE_CACHE = 64

local function PartTris(ix, iy, sub)
	local key = ix .. " " .. iy .. " " .. sub
	local t = C.traceCache[key]
	if t ~= nil then return t end
	local list, nf = C.ReadPiece(ix, iy, sub)
	t = false
	if list then
		local x0, y0 = C.PieceCorner(ix, iy, sub)
		t = { n = nf, zmin = math.huge, zmax = -math.huge }
		for i = 1, nf * 3 do
			local p = list[i].pos
			local k = (i - 1) * 3
			t[k + 1], t[k + 2], t[k + 3] = p.x + x0, p.y + y0, p.z
			if p.z < t.zmin then t.zmin = p.z end
			if p.z > t.zmax then t.zmax = p.z end
		end
	end
	C.traceCache[key] = t
	local order = C.traceOrder
	order[#order + 1] = key
	if #order > C.TRACE_CACHE then C.traceCache[table.remove(order, 1)] = nil end
	return t
end

local function RayTris(t, ox, oy, oz, dx, dy, dz, best, at)
	for i = 0, t.n - 1 do
		local k = i * 9
		local ax, ay, az = t[k + 1], t[k + 2], t[k + 3]
		local e1x, e1y, e1z = t[k + 4] - ax, t[k + 5] - ay, t[k + 6] - az
		local e2x, e2y, e2z = t[k + 7] - ax, t[k + 8] - ay, t[k + 9] - az
		local px, py, pz = dy * e2z - dz * e2y, dz * e2x - dx * e2z, dx * e2y - dy * e2x
		local det = e1x * px + e1y * py + e1z * pz
		if det > 1e-9 or det < -1e-9 then
			local inv = 1 / det
			local sx, sy, sz = ox - ax, oy - ay, oz - az
			local u = (sx * px + sy * py + sz * pz) * inv
			if u >= 0 and u <= 1 then
				local qx, qy, qz = sy * e1z - sz * e1y, sz * e1x - sx * e1z, sx * e1y - sy * e1x
				local v = (dx * qx + dy * qy + dz * qz) * inv
				if v >= 0 and u + v <= 1 then
					local f = (e2x * qx + e2y * qy + e2z * qz) * inv
					if f >= 0 and f < best then best, at = f, { t, k } end
				end
			end
		end
	end
	return best, at
end

function C.TraceAbs(a, b)
	if not C.On() then return nil end
	local P = C.PIECE
	local d = b - a
	local len2 = math.sqrt(d.x * d.x + d.y * d.y)
	local steps = math.max(1, math.ceil(len2 / (P / 8)))
	local cells, seen = {}, {}
	for i = 0, steps do
		local f = i / steps
		local ix, iy = math.floor((a.x + d.x * f) / P), math.floor((a.y + d.y * f) / P)
		local key = ix .. " " .. iy
		if not seen[key] then
			seen[key] = true
			cells[#cells + 1] = { ix, iy, f }
		end
	end
	local best, at = 1.0000001, nil
	for c = 1, #cells do
		local cell = cells[c]
		local f0 = math.max(0, cell[3] - 2 / steps)
		local nxt0 = cells[c + 1]
		local f1 = math.min(1, (nxt0 and nxt0[3] or 1) + 2 / steps)
		if len2 < P then f0, f1 = 0, 1 end
		local za, zb = a.z + d.z * f0, a.z + d.z * f1
		local zlo, zhi = math.min(za, zb) - 1, math.max(za, zb) + 1
		for _, sub in ipairs(C.PieceParts(cell[1], cell[2])) do
			local t = PartTris(cell[1], cell[2], sub)
			if t and t.zmax >= zlo and t.zmin <= zhi then best, at = RayTris(t, a.x, a.y, a.z, d.x, d.y, d.z, best, at) end
		end
		local nxt = cells[c + 1]
		if at and (not nxt or best < nxt[3] - 1 / steps) then break end
	end
	if not at then return nil end
	local t, k = at[1], at[2]
	local e1 = Vector(t[k + 4] - t[k + 1], t[k + 5] - t[k + 2], t[k + 6] - t[k + 3])
	local e2 = Vector(t[k + 7] - t[k + 1], t[k + 8] - t[k + 2], t[k + 9] - t[k + 3])
	local n = e1:Cross(e2)
	n:Normalize()
	if n:Dot(d) > 0 then n = -n end
	return best, a + d * best, n
end

local function Merge(engine, t, off)
	local f, pos, n = C.TraceAbs(t.start + off, t.endpos + off)
	if f and (not engine.Hit or f < (engine.Fraction or 1)) then
		return { Hit = true, HitWorld = true, HitNonWorld = false, HitSky = false, StartSolid = false, AllSolid = false, Fraction = f,
			FractionLeftSolid = 0, HitPos = pos - off, HitNormal = n, StartPos = t.start, Normal = (t.endpos - t.start):GetNormalized(),
			Entity = game.GetWorld and game.GetWorld() or NULL, HitTexture = "**studio**", MatType = MAT_CONCRETE or 67 }
	end
	return engine
end

function C.MergeAbs(engine, t) return Merge(engine, t, Vector(0, 0, 0)) end

C.realTraceLine = C.realTraceLine or (util and util.TraceLine)

function C.FrameFor(t)
	if CLIENT then return C.Mine and C.Mine() or nil end
	local f = t.filter
	if type(f) == "table" and not (IsEntity and IsEntity(f)) then f = f[1] end
	if IsEntity and IsEntity(f) and IsValid(f) then return C.CellOf(f) end
	return nil
end

function C.WantsWorld(t)
	local mask = t.mask or MASK_SOLID or 33570827
	return bit.band(mask, CONTENTS_SOLID or 1) ~= 0 and not t.skategmEngineOnly
end

if util and C.realTraceLine and not C.tracePatched then
	C.tracePatched = true
	C.tracePatch = function(t)
		if SPACE.busy > 0 or not (t and t.start and t.endpos and C.On() and C.WantsWorld(t)) then return C.realTraceLine(t) end
		local off = C.FrameFor(t)
		if not off then return C.realTraceLine(t) end
		return SPACE.TraceIn(t, off)
	end
	util.TraceLine = C.tracePatch
end

hook.Add("ShouldCollide", "skategm_cells", function(a, b)
	local ka, kb = a.SkateGMCell, b.SkateGMCell
	if ka and kb and ka ~= kb then return false end
end)

function C.Apart(a, b)
	if not C.On() or not (IsValid(a) and IsValid(b)) then return false end
	local ka, kb = a.SkateGMCell, b.SkateGMCell
	return ka ~= nil and kb ~= nil and ka ~= kb
end

local function Blocked(ply, ent) if C.Apart(ply, ent) then return false end end
hook.Add("PhysgunPickup", "skategm_cells", Blocked)
hook.Add("GravGunPickupAllowed", "skategm_cells", Blocked)
hook.Add("GravGunPunt", "skategm_cells", Blocked)
hook.Add("PlayerUse", "skategm_cells", Blocked)
hook.Add("CanProperty", "skategm_cells", function(ply, _, ent) return Blocked(ply, ent) end)
hook.Add("CanTool", "skategm_cells", function(ply, tr) if tr and IsValid(tr.Entity) then return Blocked(ply, tr.Entity) end end)

local ENT = {}
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "SkateGM ground"
ENT.Spawnable = false
ENT.AdminOnly = true
ENT.DisableDuplicator = true
ENT.DoNotDuplicate = true
ENT.PhysgunDisabled = true
ENT.m_tblToolsAllowed = {}

function ENT:SetupDataTables()
	self:NetworkVar("Int", 0, "PieceX")
	self:NetworkVar("Int", 1, "PieceY")
	self:NetworkVar("String", 1, "PieceSub")
	self:NetworkVar("String", 0, "CellKey")
end

function ENT:CanTool() return false end
function ENT:CanProperty() return false end
function ENT:GravGunPickupAllowed() return false end
function ENT:GravGunPunt() return false end

function ENT:Build()
	if self.built then return true end
	local list = C.ReadPiece(self:GetPieceX(), self:GetPieceY(), self:GetPieceSub())
	if not list then return false end
	self.built = true
	self:SetCustomCollisionCheck(true)
	self:PhysicsFromMesh(list)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_NONE)
	self:EnableCustomCollisions(true)
	self:DrawShadow(false)
	local phys = self:GetPhysicsObject()
	if IsValid(phys) then phys:EnableMotion(false) end
	self:CollisionRulesChanged()
	return true
end

function ENT:Initialize()
	self.SkateGMCell = self:GetCellKey()
	if SERVER then
		self:SetNoDraw(true)
		self:Build()
	end
end

function ENT:UpdateTransmitState() return TRANSMIT_ALWAYS end

function ENT:Think()
	if CLIENT then
		self.SkateGMCell = self:GetCellKey()
		if not self.built and self:GetPieceX() then
			self:Build()
			local phys = self:GetPhysicsObject()
			if IsValid(phys) then phys:SetPos(self:GetPos()) phys:SetAngles(self:GetAngles()) end
			self:SetRenderBounds(Vector(-1, -1, -1), Vector(1, 1, 1))
		end
		self:SetNextClientThink(CurTime() + 0.5)
		return true
	end
end

function ENT:Draw() end

if scripted_ents then scripted_ents.Register(ENT, C.GROUND) end
