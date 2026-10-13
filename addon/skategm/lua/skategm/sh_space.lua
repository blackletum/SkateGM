-- Where things really are, on every map: one layer both realms ask.
-- Absolute positions in, absolute positions out.
--   normal maps, InfMap2 (it detours GetPos itself): Source positions are absolute
--   streamed maps (skategm_stream/<map>/): every entity sits in a cell (NW2
--     SkateGMFrame of its root parent); its Source position is relative to it
--   the original InfMap, client only: everything is relative to my chunk
--     (SkateGM.frameOffset); the server is absolute
-- "View" is the frame client Lua works in (the skater, the HUD, rendering):
-- my cell or my chunk; on the server it is the absolute frame.
SKATEGM_SPACE = SKATEGM_SPACE or {}
local SPACE = SKATEGM_SPACE
SPACE.CELL = 8192
SPACE.KEEP = 0.75
SPACE.REACH = 1.25
SPACE.FRAMES_FOR = 0.5
SPACE.GROUND_SPAN, SPACE.GROUND_STEPS = 1536, 16
SPACE.streamed = SPACE.streamed or {}
SPACE.busy = 0

local function Zero() return Vector(0, 0, 0) end
local function NonZero(o) return o and (o.x ~= 0 or o.y ~= 0 or o.z ~= 0) and o or nil end
local function Valid(e) return e ~= nil and IsValid(e) end

function SPACE.Streamed()
	local map = game and game.GetMap and game.GetMap()
	if map then
		local s = SPACE.streamed[map]
		if s == nil and file and file.Exists then
			s = file.Exists("skategm_stream/" .. map .. "/index.json", "GAME") and true or false
			SPACE.streamed[map] = s
		end
		if s then return true end
	end
	return GetGlobal2String ~= nil and GetGlobal2String("SkateGMStream", "") ~= ""
end

function SPACE.Key(v) return math.floor(v.x / SPACE.CELL + 0.5) .. " " .. math.floor(v.y / SPACE.CELL + 0.5) end

function SPACE.Snap(abs)
	local c = SPACE.CELL
	return Vector(math.floor(abs.x / c + 0.5) * c, math.floor(abs.y / c + 0.5) * c, 0)
end

function SPACE.Root(ent)
	local root = ent
	for _ = 1, 8 do
		local p = root.GetParent and root:GetParent()
		if not Valid(p) then break end
		root = p
	end
	return root
end

-- the cell an entity is kept in (streamed maps; zero elsewhere)
function SPACE.CellOf(ent)
	if not Valid(ent) then return Zero() end
	return SPACE.Root(ent):GetNW2Vector("SkateGMFrame", Zero())
end

-- InfMap1's client frame (my chunk); nil anywhere else
function SPACE.ClientOffset()
	if not CLIENT then return nil end
	local S = SkateGM
	return NonZero(S and S.frameOffset and S.frameOffset())
end

local function FrameOrNil(ent)
	if SPACE.Streamed() then return NonZero(SPACE.CellOf(ent)) end
	return SPACE.ClientOffset()
end

-- what an entity's Source position is relative to
function SPACE.FrameOf(ent) return FrameOrNil(ent) or Zero() end

function SPACE.Abs(ent)
	local f = FrameOrNil(ent)
	if not f then return ent:GetPos() end
	return ent:GetPos() + f
end

function SPACE.ToLocal(ent, abs)
	local f = FrameOrNil(ent)
	return f and abs - f or abs
end

function SPACE.FromLocal(ent, l)
	local f = FrameOrNil(ent)
	return f and l + f or l
end

-- client Lua's frame (zero on the server)
local function ViewOrNil()
	if not CLIENT then return nil end
	local S = SkateGM
	local o = NonZero(S and S.frameOffset and S.frameOffset())
	if o then return o end
	if SPACE.Streamed() then
		local me = LocalPlayer and LocalPlayer()
		if Valid(me) then return NonZero(me:GetNW2Vector("SkateGMFrame", Zero())) end
	end
	return nil
end
function SPACE.ViewFrame() return ViewOrNil() or Zero() end
function SPACE.FromView(v) local o = ViewOrNil() return (o and v) and v + o or v end
function SPACE.ToView(v) local o = ViewOrNil() return (o and v) and v - o or v end

-- an entity (or a point of it, in its own Source frame) in the view frame
function SPACE.View(ent, l)
	l = l or ent:GetPos()
	local f, o = FrameOrNil(ent), ViewOrNil()
	if f then l = l + f end
	if o then l = l - o end
	return l
end

-- the cell a player belongs in at abs: theirs while within KEEP of it, else
-- the one under abs
function SPACE.PlayerCell(ply, abs)
	local cell = SPACE.CellOf(ply)
	local keep = SPACE.CELL * SPACE.KEEP
	if math.abs(abs.x - cell.x) > keep or math.abs(abs.y - cell.y) > keep then cell = SPACE.Snap(abs) end
	return cell
end

-- (server) a player's Source position for abs, moving them to another cell
-- when they've left theirs
function SPACE.LocalFor(ply, abs)
	if not SPACE.Streamed() then return abs end
	local old = SPACE.CellOf(ply)
	local cell = SPACE.PlayerCell(ply, abs)
	if SPACE.Key(cell) ~= SPACE.Key(old) then
		ply:SetNW2Vector("SkateGMFrame", cell)
		local C = SKATEGM_CELLS
		if C and C.SetCell and C.On() then
			C.SetCell(ply, cell)
			C.PlayerShifted(ply)
		end
	end
	return abs - cell
end

-- puts an entity at abs (choosing its cell on the server); returns its frame
function SPACE.Place(ent, abs, ang)
	if ang then ent:SetAngles(ang) end
	if CLIENT then
		local o = ViewOrNil()
		ent:SetPos(o and abs - o or abs)
		return o or Zero()
	end
	if not SPACE.Streamed() then
		ent:SetPos(abs)
		return Zero()
	end
	if ent.IsPlayer and ent:IsPlayer() then
		local l = SPACE.LocalFor(ent, abs)
		ent:SetPos(l)
		return abs - l
	end
	local C = SKATEGM_CELLS
	if C and C.Place and C.On() then return C.Place(ent, abs) end
	ent:SetPos(abs)
	return Zero()
end

-- every frame something may be in: the absolute one, each player's, each
-- tracked thing's (server) or each other cell's thing (client); refreshed
-- every FRAMES_FOR seconds
function SPACE.Frames()
	local now = (SysTime or os.clock)()
	if SPACE.frames and now - (SPACE.framesAt or -1e9) < SPACE.FRAMES_FOR then return SPACE.frames end
	local list, seen = {}, {}
	local function add(f)
		local k = SPACE.Key(f)
		if not seen[k] then
			seen[k] = true
			list[#list + 1] = Vector(f.x, f.y, 0)
		end
	end
	add(Zero())
	for _, p in ipairs(player and player.GetAll and player.GetAll() or {}) do add(SPACE.CellOf(p)) end
	local C = SKATEGM_CELLS
	local held = C and (SERVER and C.tracked or CLIENT and C.foreign)
	if held then
		for e in pairs(held) do
			if Valid(e) then add(SPACE.CellOf(e)) end
		end
	end
	SPACE.frames, SPACE.framesAt = list, now
	return list
end

-- the part [f0, f1] of a + d t inside the square of half width `half` round f
local function Clip(a, d, f, half)
	local t0, t1 = 0, 1
	for _, ax in ipairs({ "x", "y" }) do
		local lo, hi, s, dd = f[ax] - half, f[ax] + half, a[ax], d[ax]
		if math.abs(dd) < 1e-9 then
			if s < lo or s > hi then return nil end
		else
			local u0, u1 = (lo - s) / dd, (hi - s) / dd
			if u0 > u1 then u0, u1 = u1, u0 end
			if u0 > t0 then t0 = u0 end
			if u1 < t1 then t1 = u1 end
			if t0 > t1 then return nil end
		end
	end
	return t0, t1
end

-- the frames whose things can be within r of the segment a-b
function SPACE.FramesNear(a, b, r)
	local d = b - a
	local half = SPACE.CELL * SPACE.REACH + (r or 0)
	local out, seen = {}, {}
	local function try(f)
		local k = SPACE.Key(f)
		if seen[k] then return end
		seen[k] = true
		local f0, f1 = Clip(a, d, f, half)
		if f0 then out[#out + 1] = { frame = f, key = k, f0 = f0, f1 = f1 } end
	end
	local len = math.sqrt(d.x * d.x + d.y * d.y)
	local steps = math.max(1, math.ceil(len / (SPACE.CELL / 2)))
	try(SPACE.Snap(a))
	for i = 1, steps do try(SPACE.Snap(a + d * (i / steps))) end
	for _, f in ipairs(SPACE.Frames()) do try(f) end
	return out
end

-- entities within r of abs, wherever they are: the engine's search once per
-- frame near abs (a few calls), not a Lua pass over every entity
function SPACE.FindInSphere(abs, r)
	if not SPACE.Streamed() then
		local o = SPACE.ClientOffset()
		return ents.FindInSphere(o and abs - o or abs, r)
	end
	local out, seen = {}, {}
	for _, s in ipairs(SPACE.FramesNear(abs, abs, r)) do
		for _, e in ipairs(ents.FindInSphere(abs - s.frame, r)) do
			if not seen[e] and SPACE.Key(SPACE.CellOf(e)) == s.key then
				seen[e] = true
				out[#out + 1] = e
			end
		end
	end
	return out
end

---------------------------------------------------------------------------
-- traces
---------------------------------------------------------------------------
local function IsEnt(x)
	if IsEntity then return IsEntity(x) end
	return type(x) == "table" and x.GetPos ~= nil
end

-- the trace's filter as "would it hit e"
local function Allows(filter, whitelist)
	if filter == nil then return function() return true end end
	if type(filter) == "function" then return filter end
	local set = {}
	if type(filter) == "table" and not IsEnt(filter) then
		for _, e in pairs(filter) do set[e] = true end
	else
		set[filter] = true
	end
	return function(e)
		local listed = set[e] or (e.GetClass and set[e:GetClass()]) or false
		if whitelist then return listed end
		return not listed
	end
end

local function IsWorld(e) return e ~= nil and e.IsWorld ~= nil and e:IsWorld() end

local function Copy(t, a, b, filter)
	local c = {}
	for k, v in pairs(t) do c[k] = v end
	c.start, c.endpos, c.output = a, b, nil
	if filter then c.filter, c.whitelist = filter, nil end
	return c
end

local function Fill(t, out)
	if t.output then
		for k in pairs(t.output) do t.output[k] = nil end
		for k, v in pairs(out) do t.output[k] = v end
		return t.output
	end
	return out
end

-- the engine's own trace (under the util.TraceLine patch in sh_cells)
function SPACE.Real(t)
	local C = SKATEGM_CELLS
	if C and C.tracePatch and util.TraceLine == C.tracePatch then return C.realTraceLine(t) end
	SPACE.busy = SPACE.busy + 1
	local ok, tr = pcall(util.TraceLine, t)
	SPACE.busy = SPACE.busy - 1
	if not ok then error(tr, 0) end
	return tr
end

-- one frame's stretch of a ray: what's in that frame (and the world)
local function Stretch(t, key, la, lb)
	local tr = SPACE.Real(Copy(t, la, lb)) or { Hit = false, Fraction = 1, HitPos = lb }
	local e = tr.Entity
	if tr.Hit and Valid(e) and not IsWorld(e) and SPACE.Key(SPACE.CellOf(e)) ~= key then
		local allow = Allows(t.filter, t.whitelist)
		tr = SPACE.Real(Copy(t, la, lb, function(x)
			if IsWorld(x) then return allow(x) end
			return SPACE.Key(SPACE.CellOf(x)) == key and allow(x)
		end)) or { Hit = false, Fraction = 1, HitPos = lb }
	end
	return tr
end

local function Shifted(tr, o, t)
	local out = {}
	for k, v in pairs(tr) do out[k] = v end
	if out.HitPos then out.HitPos = out.HitPos + o end
	out.StartPos = t.start
	return out
end

-- like util.TraceLine, with start / endpos and HitPos absolute: the engine's
-- trace in each frame the ray passes through, plus the streamed map's own
-- ground (sh_cells), filter and mask honoured
function SPACE.Trace(t)
	if not SPACE.Streamed() then
		local o = SPACE.ClientOffset()
		if not o then return SPACE.Real(t) end
		return Fill(t, Shifted(SPACE.Real(Copy(t, t.start - o, t.endpos - o)), o, t))
	end
	local a, b = t.start, t.endpos
	local d = b - a
	local best, bestF, bestFrame, first
	for _, s in ipairs(SPACE.FramesNear(a, b, 0)) do
		local f0, f1, f = s.f0, s.f1, s.frame
		local tr = Stretch(t, s.key, a + d * f0 - f, a + d * f1 - f)
		if f0 == 0 and (not first or (tr.StartSolid and not first.tr.StartSolid)) then first = { tr = tr, f1 = f1 } end
		if tr.Hit then
			local frac = f0 + (tr.Fraction or 0) * (f1 - f0)
			if not bestF or frac < bestF then best, bestF, bestFrame = tr, frac, f end
		end
	end
	local out = {}
	for k, v in pairs(best or (first and first.tr) or {}) do out[k] = v end
	if best then
		out.Fraction = bestF
		out.HitPos = best.HitPos and best.HitPos + bestFrame or a + d * bestF
	else
		out.Hit, out.Fraction, out.HitPos = false, 1, b
	end
	if first then
		local ftr = first.tr
		out.StartSolid, out.AllSolid = ftr.StartSolid or false, ftr.AllSolid or false
		if ftr.FractionLeftSolid then out.FractionLeftSolid = ftr.FractionLeftSolid * first.f1 end
	end
	out.StartPos = a
	if d.x ~= 0 or d.y ~= 0 or d.z ~= 0 then out.Normal = d:GetNormalized() end
	local C = SKATEGM_CELLS
	if C and C.MergeAbs and C.On() and C.WantsWorld(t) then out = C.MergeAbs(out, t) end
	return Fill(t, out)
end

-- a trace in a frame of the caller's (start / endpos relative to `frame`)
function SPACE.TraceIn(t, frame)
	if not NonZero(frame) then return SPACE.Trace(t) end
	local abs = Copy(t, t.start + frame, t.endpos + frame)
	local tr = SPACE.Trace(abs)
	local out = {}
	for k, v in pairs(tr) do out[k] = v end
	if out.HitPos then out.HitPos = out.HitPos - frame end
	out.StartPos = t.start
	return Fill(t, out)
end

-- the walkable surface at (abs.x, abs.y) closest in height to abs.z: every
-- surface down a vertical line through world and props (hills, ramps, a
-- floor under a roof), not just brushes. Absolute; returns z, found
function SPACE.Ground(abs, mask)
	local x, y, ref = abs.x, abs.y, abs.z
	if not (util and util.TraceLine) then return ref, false end
	mask = mask or MASK_PLAYERSOLID
	local best, bestGap
	local function down(from, bottom)
		local z = from
		for _ = 1, SPACE.GROUND_STEPS do
			if z <= bottom then return end
			local tr = SPACE.Trace({ start = Vector(x, y, z), endpos = Vector(x, y, bottom), mask = mask })
			if not tr.Hit or tr.HitSky then return end
			if tr.StartSolid then
				-- inside a brush (a roof, a wall top): carry on from where the trace left it
				local left = tr.FractionLeftSolid or 0
				if left <= 0 or left >= 1 then return end
				z = z - (z - bottom) * left - 1
			else
				local hz = tr.HitPos.z
				if tr.HitNormal and tr.HitNormal.z > 0.5 then
					local gap = math.abs(hz - ref)
					if not bestGap or gap < bestGap then best, bestGap = hz, gap end
				end
				z = hz - 8
			end
		end
	end
	-- just over the height asked about first (the usual case: the floor is
	-- right under it), then from high up for hills and floors above
	local span = SPACE.GROUND_SPAN
	down(ref + 72, ref - span)
	if not bestGap or bestGap > 72 then down(ref + span, ref - span) end
	return best or ref, best ~= nil
end

---------------------------------------------------------------------------
-- the old names, kept for other add-ons and modes
---------------------------------------------------------------------------
function SkateGMStreamed() return SPACE.Streamed() end
function SkateGMFrame(ply) return SPACE.CellOf(ply) end
function SkateGMAbsPos(ply) return SPACE.Abs(ply) end
function SkateGMEntAbs(ent) return SPACE.Abs(ent) end
function SkateGMToLocal(ent, abs) return SPACE.ToLocal(ent, abs) end
-- positions relative to `frame`, else absolute (server) or the view frame (client)
function SkateGMTraceWorld(t, frame)
	return SPACE.TraceIn(t, frame or ViewOrNil())
end
function SkateGMLocal(ply, pos) return SPACE.LocalFor(ply, pos) end
function SkateGMPlace(ent, abs) return SPACE.Place(ent, abs) end
