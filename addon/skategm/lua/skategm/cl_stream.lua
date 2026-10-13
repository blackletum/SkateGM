local S = SkateGM

local ST = S.stream or {}
S.stream = ST
ST.DIR = "skategm_stream/"
ST.NEAR = 2
ST.KEEP = 3
ST.BUDGET = 0.004
ST.CHUNK = 1200
ST.ZFAR = 160000
ST.tiles = ST.tiles or {}
ST.queue = ST.queue or {}

local DECAL = 3
local WATER = 6

function ST.Key(ix, iy) return ix .. " " .. iy end

local function Field(t, k)
	if t == nil then return nil end
	local v = t[k]
	if v == nil then v = t[tonumber(k)] end
	if v == nil then v = t[tostring(k)] end
	return v
end

function ST.Reset()
	for _, tile in pairs(ST.tiles) do
		for lod = 0, 1 do ST.Free(tile, lod) end
	end
	for _, g in pairs(ST.grids or {}) do
		if g and g.file then pcall(g.file.Close, g.file) end
	end
	ST.tiles, ST.queue, ST.index, ST.on, ST.job, ST.warmQueue, ST.grids = {}, {}, nil, false, nil, nil, {}
	ST.topZ, ST.paused = nil, {}
end

function ST.Load(map)
	ST.Reset()
	local txt = file.Read(ST.DIR .. map .. "/index.json", "GAME")
	if not txt then return false end
	local index = util.JSONToTable(txt)
	if not index or not index.tiles then return false end
	ST.index, ST.map, ST.on = index, map, true
	ST.size = tonumber(index.tile) or 5040
	ST.cell = tonumber(index.cell) or 8192
	ST.mats, ST.lightmaps = {}, {}
	for key, t in pairs(index.tiles) do
		local ix, iy = tostring(key):match("^(%-?%d+) (%-?%d+)$")
		ix, iy = tonumber(ix), tonumber(iy)
		if ix then
			local tile = { ix = ix, iy = iy, info = {}, built = {}, origin = Vector(ix * ST.size + ST.size / 2, iy * ST.size + ST.size / 2, 0) }
			for lod = 0, 1 do
				local info = Field(t, lod)
				if info then
					tile.info[lod] = info
					if info.lo and info.hi then
						local lo, hi = Vector(info.lo[1], info.lo[2], info.lo[3]), Vector(info.hi[1], info.hi[2], info.hi[3])
						tile.centre = tile.centre and tile.centre or (lo + hi) / 2
						local r = (hi - lo):Length() / 2
						tile.radius = math.max(tile.radius or 0, r + (tile.centre - (lo + hi) / 2):Length())
					end
				end
			end
			tile.centre = tile.centre or tile.origin
			tile.radius = tile.radius or ST.size
			ST.tiles[ST.Key(ix, iy)] = tile
		end
	end
	return true
end

function ST.Material(i)
	local m = ST.mats[i]
	if m == nil then
		local def = ST.index.materials[i + 1]
		m = def and (def.kind == WATER and ST.WaterMaterial(i, def) or Material(def.name)) or false
		ST.mats[i] = m
	end
	return m or nil
end

ST.WATER_NORMAL = "nature/water_coast01_normal"
ST.WATER_UV = 630
ST.WATER_TINT = 2.6
ST.WATER_RIPPLE = 0.012
ST.WATER_DULL = 0.55
ST.WATER_DIM = 0.9
ST.WATER_HAZE = { 74, 82, 76, 125 }
ST.reflectVar = CreateClientConVar and CreateClientConVar("skategm_water_reflections", "1", true, false, "Water reflects the world (costs frame rate near water)", 0, 1)
ST.REFLECT_SCALE = 0.5
ST.REFLECT_FAR = 6000
ST.REFLECT_DETAIL = 3000
ST.REFLECT_SLOW_AT = 1500
ST.waterMats = {}
function ST.WaterTint(def)
	local base = Material(def.name)
	local name = base and not base:IsError() and base:GetString("$basetexture") or ""
	local r, g, b = name:match("w_(%x%x)(%x%x)(%x%x)$")
	return ST.Tint(tonumber(r or "26", 16), tonumber(g or "40", 16), tonumber(b or "4e", 16))
end

function ST.Tint(r, g, b)
	local k = ST.WATER_TINT / 255
	r, g, b = math.min(r * k, 1), math.min(g * k, 1), math.min(b * k, 1)
	local grey = (r + g + b) / 3
	local d, k2 = ST.WATER_DULL, ST.WATER_DIM
	return (r + (grey - r) * d) * k2, (g + (grey - g) * d) * k2, (b + (grey - b) * d) * k2
end

function ST.WaterMaterial(i, def)
	local m = ST.MakeWater("sgm_water_" .. ST.map .. "_" .. i, ST.WaterTint(def))
	return m or Material(def.name)
end

function ST.MakeWater(name, r, g, b)
	local m = CreateMaterial(name, "Refract", {
		["$normalmap"] = ST.WATER_NORMAL,
		["$refracttint"] = string.format("[%f %f %f]", r, g, b),
		["$refractamount"] = ST.WATER_RIPPLE,
		["$bluramount"] = 0,
		["$nocull"] = 1,
		["$nofog"] = 1,
		["$bumptransform"] = "center .5 .5 scale 1 1 rotate 0 translate 0 0",
		Proxies = { TextureScroll = { texturescrollvar = "$bumptransform", texturescrollrate = 0.03, texturescrollangle = 30 } },
	})
	if not m or m:IsError() then return nil end
	ST.waterMats[#ST.waterMats + 1] = m
	if ST.reflectRT then m:SetTexture("$basetexture", ST.reflectRT) end
	return m
end

ST.SEA_RAYS_X, ST.SEA_RAYS_Y = 6, 4
ST.SEA_DEPTH = 256

function ST.InView(pos, radius)
	local eye = ST.eyeAbs
	local to = pos - eye
	local d = to:Length()
	if d - radius > ST.REFLECT_FAR then return false end
	if d <= radius then return true end
	return to:Dot(EyeAngles():Forward()) > -radius
end

function ST.LandAt(d, abs, z)
	local levels = d and ST.Levels(d, "ground", abs)
	if not levels then return false end
	for _, v in ipairs(levels) do
		if v > z - ST.SEA_DEPTH then return true end
	end
	return false
end

function ST.SeaVisible(z)
	local eye = ST.eyeAbs
	local _, d = ST.Here()
	local ang = EyeAngles()
	local f, r, u = ang:Forward(), ang:Right(), ang:Up()
	local tx = math.tan(math.rad((ST.viewFov or 75) / 2))
	local ty = tx * ScrH() / ScrW()
	for i = 0, ST.SEA_RAYS_X - 1 do
		for j = 0, ST.SEA_RAYS_Y - 1 do
			local sx = (i + 0.5) / ST.SEA_RAYS_X * 2 - 1
			local sy = (j + 0.5) / ST.SEA_RAYS_Y * 2 - 1
			local dir = f + r * (sx * tx) - u * (sy * ty)
			if dir.z < -1e-3 then
				local t = (z - eye.z) / dir.z
				local hit = eye + dir * t
				if (hit - eye):Length2D() < ST.REFLECT_FAR * 2 and not ST.LandAt(d, hit, z) then return true end
			end
		end
	end
	return false
end

function ST.WaterVisible(z, box)
	if box then
		local c = Vector((box[1] + box[3]) / 2, (box[2] + box[4]) / 2, z)
		local radius = math.sqrt((box[3] - box[1]) ^ 2 + (box[4] - box[2]) ^ 2) / 2
		return ST.InView(c, radius)
	end
	return ST.SeaVisible(z)
end

function ST.SawWater(z, box)
	local eye = ST.eyeAbs
	if not eye then return end
	local dz = eye.z - z
	if dz < 0 then return end
	if not ST.WaterVisible(z, box) then return end
	local dx = box and math.max(box[1] - eye.x, 0, eye.x - box[3]) or 0
	local dy = box and math.max(box[2] - eye.y, 0, eye.y - box[4]) or 0
	local d = math.sqrt(dx * dx + dy * dy + dz * dz)
	local seen = ST.waterSeen
	if not seen or d < seen.d then ST.waterSeen = { z = z, d = d } end
end

function ST.ReflectTargets()
	local w, h = math.max(64, math.floor(ScrW() * ST.REFLECT_SCALE)), math.max(64, math.floor(ScrH() * ST.REFLECT_SCALE))
	if ST.reflectW ~= w or ST.reflectH ~= h then
		ST.reflectW, ST.reflectH = w, h
		local tag = w .. "x" .. h
		ST.reflectRaw = GetRenderTarget("sgm_reflect_raw_" .. tag, w, h)
		ST.reflectRT = GetRenderTarget("sgm_reflect_" .. tag, w, h)
		ST.reflectCopy = CreateMaterial("sgm_reflect_copy_" .. tag, "UnlitGeneric", { ["$basetexture"] = ST.reflectRaw:GetName(), ["$ignorez"] = 1, ["$vertexcolor"] = 1 })
		for _, m in ipairs(ST.waterMats) do m:SetTexture("$basetexture", ST.reflectRT) end
	end
	return ST.reflectRaw, ST.reflectRT
end

function ST.ClearReflection()
	if ST.reflectStale or not ST.reflectRT then return end
	ST.reflectStale = true
	local hz = ST.WATER_HAZE
	render.PushRenderTarget(ST.reflectRT)
	render.Clear(hz[1], hz[2], hz[3], 255, true, true)
	render.PopRenderTarget()
end

function ST.Reflect(origin, angles, fov)
	ST.waterNear, ST.reflectedLevel = ST.waterSeen, nil
	ST.waterSeen = nil
	local near = ST.waterNear
	if ST.reflecting then return end
	local skip = not near or ST.reflectOn == false or not ST.on or ST.arrive or (ST.reflectVar and not ST.reflectVar:GetBool())
	local h = near and near.z - ST.Frame().z
	if skip or origin.z < h + 1 then
		ST.ClearReflection()
		return
	end
	ST.reflectStale = nil
	if near.d > ST.REFLECT_SLOW_AT and ST.reflectedFrame == FrameNumber() - 1 then
		ST.reflectedLevel = near.z
		return
	end
	ST.reflectedFrame = FrameNumber()
	local raw, out = ST.ReflectTargets()
	local view = {
		origin = Vector(origin.x, origin.y, 2 * h - origin.z),
		angles = Angle(-angles.p, angles.y, -angles.r),
		fov = fov, x = 0, y = 0, w = ST.reflectW, h = ST.reflectH,
		drawviewmodel = false, drawhud = false, drawmonitors = false, dopostprocess = false, bloomtone = false,
		zfar = ST.REFLECT_FAR,
	}
	ST.reflecting = true
	render.PushRenderTarget(raw)
	local hz = ST.WATER_HAZE
	render.Clear(hz[1], hz[2], hz[3], 255, true, true)
	local clip = render.EnableClipping(true)
	render.PushCustomClipPlane(Vector(0, 0, 1), h)
	local ok = pcall(render.RenderView, view)
	render.PopCustomClipPlane()
	render.EnableClipping(clip)
	render.PopRenderTarget()
	render.PushRenderTarget(out)
	cam.Start2D()
	surface.SetDrawColor(255, 255, 255, 255)
	surface.SetMaterial(ST.reflectCopy)
	surface.DrawTexturedRectUV(0, 0, ST.reflectW, ST.reflectH, 0, 1, 1, 0)
	local hz = ST.WATER_HAZE
	surface.SetDrawColor(hz[1], hz[2], hz[3], hz[4])
	surface.DrawRect(0, 0, ST.reflectW, ST.reflectH)
	cam.End2D()
	render.PopRenderTarget()
	ST.reflecting = false
	if ok then ST.reflectedLevel = near.z end
end

function ST.Lightmap(name)
	local t = ST.lightmaps[name]
	if t == nil then
		local m = CreateMaterial("sgm_lm_" .. name:gsub("[^%w]", "_"), "UnlitGeneric", { ["$basetexture"] = name })
		t = m and m:GetTexture("$basetexture") or false
		ST.lightmaps[name] = t
	end
	return t or nil
end

function ST.Free(tile, lod)
	local b = tile.built[lod]
	if b then
		for _, g in ipairs(b.groups or {}) do
			for _, m in ipairs(g.meshes) do if IsValid(m) then m:Destroy() end end
		end
	end
	tile.built[lod] = nil
	local job = tile.jobs and tile.jobs[lod]
	if job then
		job.cancelled = true
		tile.jobs[lod] = nil
	end
end

local byte = string.byte
local POS, UV = 1 / 32, 1 / 65536
local function I32(a, b, c, d)
	local v = a + b * 256 + c * 65536 + d * 16777216
	if d >= 128 then v = v - 4294967296 end
	return v
end

local function ReadGroup(data, at, tile, lod)
	local m0, m1, lit, atlas = byte(data, at, at + 3)
	local mat = m0 + m1 * 256
	local nv = I32(byte(data, at + 4, at + 7))
	local ni = I32(byte(data, at + 8, at + 11))
	at = at + 12
	local px, py, pz, tu, tv, lu, lv = {}, {}, {}, {}, {}, {}, {}
	local stride = lit == 1 and 24 or 20
	local yieldAt = 6000
	for i = 1, nv do
		local a1, a2, a3, a4, b1, b2, b3, b4, c1, c2, c3, c4, d1, d2, d3, d4, e1, e2, e3, e4, f1, f2, f3, f4 = byte(data, at, at + stride - 1)
		px[i] = I32(a1, a2, a3, a4) * POS
		py[i] = I32(b1, b2, b3, b4) * POS
		pz[i] = I32(c1, c2, c3, c4) * POS
		tu[i] = I32(d1, d2, d3, d4) * UV
		tv[i] = I32(e1, e2, e3, e4) * UV
		if lit == 1 then
			lu[i] = (f1 + f2 * 256) / 65535
			lv[i] = (f3 + f4 * 256) / 65535
		end
		at = at + stride
		if i == yieldAt then yieldAt = yieldAt + 6000 coroutine.yield() end
	end
	local idx = {}
	for i = 1, ni do
		local lo, hi = byte(data, at, at + 1)
		idx[i] = lo + hi * 256 + 1
		at = at + 2
	end
	coroutine.yield()
	local material = ST.Material(mat)
	local def = ST.index.materials[mat + 1]
	local water = def and def.kind == WATER
	local g = { material = material, decal = def and (def.kind == DECAL or water), water = water, meshes = {} }
	if water then
		local k = 1 / ST.WATER_UV
		local lo, hi = math.huge, -math.huge
		for i = 1, nv do
			tu[i], tv[i] = px[i] * k, py[i] * k
			if pz[i] < lo then lo = pz[i] end
			if pz[i] > hi then hi = pz[i] end
		end
		g.waterLo, g.waterHi = lo + tile.origin.z, hi + tile.origin.z
		g.waterZ = g.waterHi
		local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
		for i = 1, nv do
			if px[i] < x0 then x0 = px[i] end
			if px[i] > x1 then x1 = px[i] end
			if py[i] < y0 then y0 = py[i] end
			if py[i] > y1 then y1 = py[i] end
		end
		g.waterBox = { x0 + tile.origin.x, y0 + tile.origin.y, x1 + tile.origin.x, y1 + tile.origin.y }
	end
	local sheet = lit == 1 and ST.index.atlases and ST.index.atlases[atlas + 1]
	if sheet then g.lightmap = ST.Lightmap(sheet) end
	local Begin, End, Pos, Tex, Adv = mesh.Begin, mesh.End, mesh.Position, mesh.TexCoord, mesh.AdvanceVertex
	local tris = ni / 3
	local done = 0
	while done < tris do
		local n = math.min(ST.CHUNK, tris - done)
		local m = Mesh(material)
		Begin(m, MATERIAL_TRIANGLES, n)
		local k = done * 3
		if water then
			local Normal, TS, TT, Up, X, Y = mesh.Normal, mesh.TangentS, mesh.TangentT, Vector(0, 0, 1), Vector(1, 0, 0), Vector(0, 1, 0)
			for j = k + 1, k + n * 3 do
				local v = idx[j]
				Pos(px[v], py[v], pz[v])
				Normal(Up)
				TS(X)
				TT(Y)
				Tex(0, tu[v], tv[v])
				Adv()
			end
		elseif lit == 1 then
			for j = k + 1, k + n * 3 do
				local v = idx[j]
				Pos(px[v], py[v], pz[v])
				Tex(0, tu[v], tv[v])
				Tex(1, lu[v], lv[v])
				Adv()
			end
		else
			for j = k + 1, k + n * 3 do
				local v = idx[j]
				Pos(px[v], py[v], pz[v])
				Tex(0, tu[v], tv[v])
				Adv()
			end
		end
		End()
		g.meshes[#g.meshes + 1] = m
		done = done + n
		coroutine.yield()
	end
	return g, at
end

local function BuildTile(tile, lod, job)
	local info = tile.info[lod]
	local f = file.Open(ST.DIR .. ST.map .. "/" .. info.file, "rb", "GAME")
	if not f then return nil end
	local data = f:Read(f:Size())
	f:Close()
	if not data or data:sub(1, 4) ~= "SGT2" then return nil end
	coroutine.yield()
	local ok, result = pcall(function()
		local n = I32(byte(data, 5, 8))
		local at = 9
		local groups = {}
		for i = 1, n do
			if job.cancelled then break end
			local g
			g, at = ReadGroup(data, at, tile, lod)
			groups[#groups + 1] = g
		end
		return groups
	end)
	if not ok then
		ErrorNoHalt("[SkateGM] stream tile " .. info.file .. ": " .. tostring(result) .. "\n")
		return nil
	end
	return result
end

function ST.Start(tile, lod)
	tile.jobs = tile.jobs or {}
	local paused = tile.jobs[lod]
	if paused then
		ST.paused[paused] = nil
		ST.job = paused
		return
	end
	local job = { tile = tile, lod = lod }
	job.co = coroutine.create(function()
		local groups = BuildTile(tile, lod, job)
		if job.cancelled then
			for _, g in ipairs(groups or {}) do for _, m in ipairs(g.meshes) do if IsValid(m) then m:Destroy() end end end
			return
		end
		tile.built[lod] = { groups = groups or {}, born = (not ST.arrive and ST.fadeOn ~= false) and RealTime() or nil }
		ST.statTiles = (ST.statTiles or 0) + 1
		ST.statTris = (ST.statTris or 0) + (tile.info[lod] and tile.info[lod].tris or 0)
	end)
	tile.jobs[lod] = job
	ST.job = job
end

function ST.Score(tile, lod, cam, lead)
	return (lod == 0 and 0 or 1e9) + ((tile.centre - cam):Length2D() + (tile.centre - (lead or cam)):Length2D()) / 2
end

function ST.Lead(now)
	local cam = ST.Camera()
	local last, lastT = ST.leadCam, ST.leadT
	ST.leadCam, ST.leadT = cam, now
	if ST.focus or not last or now <= lastT or (cam - last):Length() > ST.ARRIVE_JUMP then
		ST.leadVel = Vector(0, 0, 0)
	else
		local v = (cam - last) / (now - lastT)
		local old = ST.leadVel or v
		ST.leadVel = old + (v - old) * math.min(1, (now - lastT) * 4)
	end
	local ahead = ST.leadVel * ST.LEAD
	local most = ST.size * 1.5
	if ahead:Length2D() > most then ahead = ahead * (most / ahead:Length2D()) end
	ST.lead = cam + ahead
	return ST.lead
end

ST.stable = ST.stable or {}

function ST.Stable(slot, eye)
	local o = ST.Frame()
	local abs = eye + o
	local s = ST.stable[slot]
	if s and s.o ~= o and (abs - s.abs):Length() > ST.ARRIVE_JUMP and (eye + s.o - s.abs):Length() < ST.ARRIVE_JUMP then
		return eye + s.o
	end
	ST.stable[slot] = { abs = abs, o = o }
	return abs
end

function ST.Camera()
	if ST.focus then return ST.focus end
	local eye = ST.renderOrigin and RealTime() - (ST.renderAt or 0) < 0.5 and ST.renderOrigin or (S.view and S.view.origin) or EyePos()
	return ST.Stable("cam", eye)
end

function ST.Me()
	local p = S.pose and S.pose.pos
	local me = LocalPlayer()
	local here = p and Vector(p[1], p[2], p[3]) or (IsValid(me) and me:GetPos()) or nil
	if not here then return nil end
	return ST.Stable("me", here)
end

function ST.Want()
	local cam = ST.Camera()
	local me = ST.Me() or cam
	local lead = ST.lead or cam
	local size = ST.size
	local cx, cy = math.floor(cam.x / size), math.floor(cam.y / size)
	local mx, my = math.floor(me.x / size), math.floor(me.y / size)
	local best, bestD
	for _, tile in pairs(ST.tiles) do
		local d = math.min(math.max(math.abs(tile.ix - cx), math.abs(tile.iy - cy)), math.max(math.abs(tile.ix - mx), math.abs(tile.iy - my)))
		tile.dist = d
		if d > ST.KEEP and tile.built[0] then
			tile.leftAt = tile.leftAt or RealTime()
			if RealTime() - tile.leftAt > ST.KEEP_FOR then
				local tf = SysTime()
				ST.Free(tile, 0)
				local spent = SysTime() - tf
				if spent > (ST.worstFree or 0) then ST.worstFree = spent end
			end
		else
			tile.leftAt = nil
		end
		local far = math.min((tile.centre - cam):Length2D(), (tile.centre - me):Length2D())
		if far > ST.ZFAR * 1.25 and tile.built[1] then ST.Free(tile, 1) end
		local wantLod
		if d <= ST.NEAR and tile.info[0] and not tile.built[0] then wantLod = 0
		elseif tile.info[1] and not tile.built[1] and far < ST.ZFAR then wantLod = 1 end
		local running = ST.job and ST.job.tile == tile and ST.job.lod == wantLod
		if wantLod and not running then
			local score = math.min(ST.Score(tile, wantLod, cam, lead), ST.Score(tile, wantLod, me, me))
			if not bestD or score < bestD then best, bestD = { tile, wantLod, score }, score end
		end
	end
	return best
end

-- materials and lightmaps load from disk when first used: warm them one a
-- frame from the start, so riding into new tiles doesn't wait on them
function ST.Warm()
	local q = ST.warmQueue
	if not q or #q == 0 then
		if (ST.nextWarmScan or 0) > RealTime() then return false end
		ST.nextWarmScan = RealTime() + 0.5
		q = {}
		for _, tile in pairs(ST.tiles) do
			if tile.dist and tile.dist <= ST.NEAR + 2 then
				for lod = 0, 1 do
					local info = tile.info[lod]
					for _, m in ipairs(info and info.mats or {}) do
						if ST.mats[m] == nil then q[#q + 1] = { false, m } end
					end
					for _, k in ipairs(info and info.atl or {}) do
						local name = ST.index.atlases[k + 1]
						if name and ST.lightmaps[name] == nil then q[#q + 1] = { true, name } end
					end
				end
			end
		end
		ST.warmQueue = q
	end
	local e = table.remove(q)
	if not e then return false end
	if e[1] then
		ST.Lightmap(e[2])
	elseif ST.mats[e[2]] == nil then
		local m = ST.Material(e[2])
		if m then m:GetTexture("$basetexture") end
	end
	return true
end

-- Arriving somewhere new (spawn, teleport, another district): the screen
-- stays dark, loading runs flat out, until the tiles around you are in
ST.ARRIVE_JUMP = 3000
ST.ARRIVE_BUDGET = 0.06
ST.ARRIVE_MAX = 12
ST.FADE = 0.4
ST.LEAD = 0.6
ST.KEEP_FOR = 1
ST.PREEMPT = 2000
ST.SHIFT_GRACE = 0.25
ST.SPINNER_AFTER = 0.15

function ST.Arrive()
	if not ST.on then return end
	ST.arrive, ST.faded = RealTime(), nil
end

function ST.NearReady()
	for _, tile in pairs(ST.tiles) do
		if tile.dist and tile.dist <= 1 and tile.info[0] and not tile.built[0] then return false end
	end
	return true
end

function ST.ArriveThink()
	local cam = ST.Me() or ST.Camera()
	local last = ST.lastCam
	local frame = ST.Frame()
	local shifted = ST.arriveFrame and ST.arriveFrame ~= frame
	ST.lastCam, ST.arriveFrame = cam, frame
	local now = RealTime()
	if shifted then ST.shiftedAt = now end
	local settling = ST.shiftedAt and now - ST.shiftedAt < ST.SHIFT_GRACE
	if not last or (not settling and (cam - last):Length() > ST.ARRIVE_JUMP) then
		ST.arrive, ST.faded = now, nil
	end
	if ST.arrive and ((ST.NearReady() and now - ST.arrive > 0.3) or now - ST.arrive > ST.ARRIVE_MAX) then
		ST.arrive, ST.faded = nil, now
	end
end

function ST.Spinner(w, h, now)
	local cx, cy, r = w / 2, h * 0.86, math.max(10, h * 0.014)
	local k = math.Clamp((now - ST.loadingSince - ST.SPINNER_AFTER) / 0.2, 0, 1)
	draw.RoundedBox(8, cx - r * 9, cy - r * 1.9, r * 18, r * 3.8, Color(0, 0, 0, 150 * k))
	for i = 0, 7 do
		local ang = i / 8 * math.pi * 2 + now * 5
		local x, y = cx - r * 6 + math.cos(ang) * r, cy + math.sin(ang) * r
		surface.SetDrawColor(255, 255, 255, (60 + 195 * (1 - i / 8)) * k)
		surface.DrawRect(x - 2, y - 2, 4, 4)
	end
	draw.SimpleText("Loading area", "DermaDefaultBold", cx - r * 3.6, cy, Color(255, 255, 255, 230 * k), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
end

function ST.Paint()
	if not ST.on then return end
	local now = RealTime()
	local w, h = ScrW(), ScrH()
	if not ST.arrive and not ST.NearReady() then
		ST.loadingSince = ST.loadingSince or now
		if now - ST.loadingSince > ST.SPINNER_AFTER then ST.Spinner(w, h, now) end
	else
		ST.loadingSince = nil
	end
	local a
	if ST.arrive then a = 1
	elseif ST.faded and now - ST.faded < ST.FADE then a = 1 - (now - ST.faded) / ST.FADE end
	if not a then return end
	surface.SetDrawColor(0, 0, 0, 255 * a)
	surface.DrawRect(0, 0, w, h)
	if ST.arrive then
		local _, d = ST.Here()
		local n, total = 0, 0
		for _, tile in pairs(ST.tiles) do
			if tile.dist and tile.dist <= 1 and tile.info[0] then
				total = total + 1
				if tile.built[0] then n = n + 1 end
			end
		end
		if S.PaintWait then
			ST.painting = true
			S.PaintWait(w, h, now, ST.arrive, d and ("Loading " .. d.title) or "Loading", nil, true, total > 0 and n / total or 0)
			ST.painting = nil
		else
			draw.SimpleText("Loading", "DermaLarge", w / 2, h / 2, Color(255, 255, 255, 255 * a), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
	end
end

function ST.Think()
	if not ST.on then return end
	if S.FrameThink then S.FrameThink() end
	ST.DistrictThink()
	local start = SysTime()
	local tw = SysTime()
	if ST.Warm() then
		local spent = SysTime() - tw
		if spent > (ST.worstWarm or 0) then ST.worstWarm = spent end
	end
	ST.ArriveThink()
	local budget = ST.arrive and ST.ARRIVE_BUDGET or ST.BUDGET
	local lead = ST.Lead(RealTime())
	if ST.job and not ST.job.cancelled then
		local want = ST.Want()
		if want and want[3] + ST.PREEMPT < ST.Score(ST.job.tile, ST.job.lod, ST.Camera(), lead) then
			ST.paused[ST.job] = true
			ST.job = nil
		end
	end
	while SysTime() - start < budget do
		local job = ST.job
		if not job then
			for p in pairs(ST.paused) do
				if p.cancelled then job = p ST.paused[p] = nil break end
			end
			if job then
				ST.job = job
			else
				local want = ST.Want()
				if not want then break end
				ST.Start(want[1], want[2])
				job = ST.job
			end
		end
		local t1 = SysTime()
		local ok, err = coroutine.resume(job.co)
		local spent = SysTime() - t1
		ST.statTime = (ST.statTime or 0) + spent
		if spent > (ST.worstResume or 0) then ST.worstResume, ST.worstWhat = spent, (job.tile.ix .. " " .. job.tile.iy .. " lod " .. job.lod) end
		if not ok then
			ErrorNoHalt("[SkateGM] stream: " .. tostring(err) .. "\n")
			job.tile.info[job.lod] = nil
			if job.tile.jobs then job.tile.jobs[job.lod] = nil end
			ST.job = nil
		elseif coroutine.status(job.co) == "dead" then
			if job.tile.jobs and job.tile.jobs[job.lod] == job then job.tile.jobs[job.lod] = nil end
			ST.job = nil
		end
	end
end

-- Lua sees positions relative to the frame the server keeps my player in
-- (cells of ST.cell units: Source can't place anything past 16384); the
-- engine, the network and the stream files use absolute ones
function ST.Frame()
	local me = LocalPlayer()
	if not IsValid(me) then return Vector(0, 0, 0) end
	return me:GetNW2Vector("SkateGMFrame", Vector(0, 0, 0))
end

local mtx = Matrix()
function ST.DrawFrame()
	local fn = FrameNumber and FrameNumber() or 0
	if ST.dfN == fn and ST.dfFrame then return ST.dfFrame end
	ST.dfN = fn
	local o = ST.Frame()
	local eye = EyePos()
	local last, lastO = ST.dfEye, ST.dfFrame
	if last and lastO and o ~= lastO and (eye + o - last):Length() > ST.ARRIVE_JUMP and (eye + lastO - last):Length() < ST.ARRIVE_JUMP then
		o = lastO
	end
	ST.dfEye, ST.dfFrame = eye + o, o
	return o
end

ST.FADE_IN = 0.5
ST.fades = ST.fades or {}

local function MaterialValue(v)
	local t = type(v)
	if t == "ITexture" then return v:GetName() end
	if t == "Vector" then return string.format("[%f %f %f]", v.x, v.y, v.z) end
	if t == "number" or t == "string" then return tostring(v) end
	return nil
end

function ST.FadeMaterial(m)
	local name = m:GetName()
	local f = ST.fades[name]
	if f == nil then
		local shader = (m:GetShader() or "LightmappedGeneric"):gsub("_DX%d+$", "")
		local kv = {}
		for k, v in pairs(m:GetKeyValues() or {}) do
			local s = MaterialValue(v)
			if s and k ~= "$flags" and k ~= "$flags2" and k ~= "$flags_defined" and k ~= "$flags_defined2" then kv[k] = s end
		end
		kv["$translucent"], kv["$alpha"], kv["$alphatest"] = 1, 1, nil
		ST.fadeCount = (ST.fadeCount or 0) + 1
		f = CreateMaterial("sgm_fade_" .. ST.fadeCount, shader, kv) or false
		ST.fades[name] = f
	end
	return f or nil
end

function ST.Fading(b, now)
	return b and b.born and now - b.born < ST.FADE_IN
end

local function DrawGroups(b, decals, alpha)
	for _, g in ipairs(b.groups) do
		if (decals == "water" and g.water or not g.water and g.decal == decals) and g.material then
			local mat = g.material
			if g.water then
				if ST.reflecting then mat = nil end
				ST.SawWater(g.waterZ, g.waterBox)
			end
			if alpha and not g.water then
				mat = ST.FadeMaterial(g.material)
				if mat then mat:SetFloat("$alpha", alpha) end
			end
			if mat then
				ST.drawnGroups = (ST.drawnGroups or 0) + 1
				render.SetMaterial(mat)
				if g.lightmap then render.SetLightmapTexture(g.lightmap) end
				for _, m in ipairs(g.meshes) do m:Draw() end
			end
		end
	end
end

local function DrawPass(decals)
	local o = ST.DrawFrame()
	local eye = EyePos() + o
	local fwd = EyeAngles():Forward()
	local now = RealTime()
	local fading
	for _, tile in pairs(ST.tiles) do
		local b = tile.built[0]
		if not (b and tile.dist and tile.dist <= ST.KEEP) then b = tile.built[1] end
		if ST.reflecting and tile.built[1] and (tile.dist or 0) > ST.REFLECT_DETAIL then b = tile.built[1] end
		if b then
			local to = tile.centre - eye
			local r = tile.radius
			if to:Dot(fwd) > -r and to:Length() - r < (ST.reflecting and ST.REFLECT_FAR or ST.ZFAR) then
				mtx:SetTranslation(tile.origin - o)
				cam.PushModelMatrix(mtx)
				ST.drawnTiles = (ST.drawnTiles or 0) + 1
				if ST.Fading(b, now) then
					if tile.built[1] and b ~= tile.built[1] then DrawGroups(tile.built[1], decals) end
					if not decals then
						fading = fading or {}
						fading[#fading + 1] = { tile, b }
					end
				else
					b.born = nil
					DrawGroups(b, decals)
				end
				cam.PopModelMatrix()
			end
		end
	end
	if not fading then return end
	render.OverrideDepthEnable(true, true)
	for _, f in ipairs(fading) do
		local tile, b = f[1], f[2]
		mtx:SetTranslation(tile.origin - o)
		cam.PushModelMatrix(mtx)
		local k = math.Clamp((now - b.born) / ST.FADE_IN, 0, 1)
		DrawGroups(b, false, k * k * (3 - 2 * k))
		cam.PopModelMatrix()
	end
	render.OverrideDepthEnable(false)
end

function ST.WatchDrops()
	local n = ST.drawnTiles or 0
	local last = ST.lastDrawn
	ST.lastDrawn = n
	if not last or last < 8 or n >= last * 0.3 then return end
	local built0, built1 = 0, 0
	for _, t in pairs(ST.tiles) do
		if t.built[0] then built0 = built0 + 1 end
		if t.built[1] then built1 = built1 + 1 end
	end
	local line = string.format("%s drawn %d -> %d | frame %s drawFrame %s eye %s view %s | arrive %s focus %s | built %d/%d",
		os.date("%H:%M:%S"), last, n, tostring(ST.Frame()), tostring(ST.dfFrame), tostring(EyePos()), tostring(S.view and S.view.origin),
		tostring(ST.arrive), tostring(ST.focus), built0, built1)
	ST.drops = (ST.drops or 0) + 1
	if ST.drops <= 200 then
		file.CreateDir("skategm")
		file.Append("skategm/stream_drops.txt", line .. "\n")
	end
end

ST.drawOn = true
function ST.Draw(depth, sky, sky3d)
	if not ST.on or sky3d or not ST.drawOn or ST.arrive then return end
	if ST.reflecting then
		DrawPass(false)
		return
	end
	local t0 = SysTime()
	ST.lastTiles, ST.lastGroups = ST.drawnTiles, ST.drawnGroups
	ST.drawnTiles, ST.drawnGroups = 0, 0
	ST.eyeAbs = EyePos() + ST.DrawFrame()
	DrawPass(false)
	if ST.decalsOn ~= false then DrawPass(true) end
	local fog = render.GetFogMode()
	render.FogMode(MATERIAL_FOG_NONE)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	ST.DrawSea()
	DrawPass("water")
	render.OverrideBlend(false)
	render.FogMode(fog)
	ST.WatchDrops()
	local spent = SysTime() - t0
	if spent > (ST.worstDraw or 0) then ST.worstDraw = spent end
end

---------------------------------------------------------------------------
-- Districts: each district is placed apart from the others; the one
-- you're in sets the sky, the sea and the water level
---------------------------------------------------------------------------
function ST.DistrictAt(abs)
	local best, bestD
	for i, d in ipairs(ST.index and ST.index.districts or {}) do
		local lo, hi = d.lo, d.hi
		local cx, cy = (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2
		local dist = math.max(math.abs(abs.x - cx) - (hi[1] - lo[1]) / 2, math.abs(abs.y - cy) - (hi[2] - lo[2]) / 2)
		if not bestD or dist < bestD then best, bestD = i, dist end
	end
	return best, best and ST.index.districts[best]
end

function ST.Here()
	return ST.DistrictAt(ST.Camera())
end

-- each district's own sky, drawn over the map's (the 2D sky can't be swapped
-- at runtime): six faces around the eye, the way the builder renders them
-- (skybox.py FACES: forward, right, down)
ST.SKY = {
	{ "rt", Vector(1, 0, 0), Vector(0, -1, 0), Vector(0, 0, -1) },
	{ "bk", Vector(0, 1, 0), Vector(1, 0, 0), Vector(0, 0, -1) },
	{ "lf", Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, 0, -1) },
	{ "ft", Vector(0, -1, 0), Vector(-1, 0, 0), Vector(0, 0, -1) },
	{ "up", Vector(0, 0, 1), Vector(0, -1, 0), Vector(1, 0, 0) },
	{ "dn", Vector(0, 0, -1), Vector(0, -1, 0), Vector(-1, 0, 0) },
}
ST.skyMats = {}
function ST.SetSky(name) ST.sky = name end

function ST.DrawSky()
	if not ST.on or not ST.sky or ST.sky == ST.index.skyname then return end
	local mats = ST.skyMats[ST.sky]
	if not mats then
		mats = {}
		for i, f in ipairs(ST.SKY) do mats[i] = Material("skybox/" .. ST.sky .. f[1]) end
		ST.skyMats[ST.sky] = mats
	end
	cam.Start3D(Vector(0, 0, 0), EyeAngles())
	render.OverrideDepthEnable(true, false)
	local k = 32
	for i, f in ipairs(ST.SKY) do
		local fw, r, d = f[2] * k, f[3] * k, f[4] * k
		render.SetMaterial(mats[i])
		render.DrawQuad(fw - r - d, fw + r - d, fw + r + d, fw - r + d)
	end
	render.OverrideDepthEnable(false, false)
	cam.End3D()
end

function ST.DistrictThink()
	local i, d = ST.Here()
	if not d then return end
	if i ~= ST.district then
		ST.district = i
		if d.sky then ST.SetSky(d.sky) end
	end
end

local seaMat
function ST.DrawSea()
	local i, d = ST.Here()
	local sea = d and d.sea
	if not sea then return end
	local col = sea.colour
	local key = col[1] .. "_" .. col[2] .. "_" .. col[3]
	ST.seaMats = ST.seaMats or {}
	local mat = ST.seaMats[key]
	if mat == nil then
		mat = ST.MakeWater("sgm_sea_" .. ST.map .. "_" .. key, ST.Tint(col[1], col[2], col[3])) or false
		ST.seaMats[key] = mat
	end
	if not mat then
		seaMat = seaMat or CreateMaterial("sgm_stream_sea", "UnlitGeneric", { ["$basetexture"] = "color/white", ["$vertexcolor"] = 1, ["$vertexalpha"] = 0 })
		mat = seaMat
	end
	local o = ST.DrawFrame()
	local lo, hi = d.lo, d.hi
	local centre = Vector((lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2, sea.z)
	ST.SawWater(sea.z, nil)
	if ST.seaMesh == nil then ST.seaMesh = ST.SeaMesh() or false end
	render.SetMaterial(mat)
	if ST.seaMesh then
		mtx:SetTranslation(centre - o)
		cam.PushModelMatrix(mtx)
		ST.seaMesh:Draw()
		cam.PopModelMatrix()
	else
		render.DrawQuadEasy(centre - o, Vector(0, 0, 1), ST.SEA_SIZE, ST.SEA_SIZE, Color(col[1], col[2], col[3]), 0)
	end
end

function ST.SeaMesh()
	if not Mesh then return nil end
	local h = ST.SEA_SIZE / 2
	local k = 1 / ST.WATER_UV
	local m = Mesh()
	local up, x, y = Vector(0, 0, 1), Vector(1, 0, 0), Vector(0, 1, 0)
	local corners = { { -h, -h }, { h, -h }, { h, h }, { -h, -h }, { h, h }, { -h, h } }
	mesh.Begin(m, MATERIAL_TRIANGLES, 2)
	for _, c in ipairs(corners) do
		mesh.Position(Vector(c[1], c[2], 0))
		mesh.Normal(up)
		mesh.TangentS(x)
		mesh.TangentT(y)
		mesh.TexCoord(0, c[1] * k, c[2] * k)
		mesh.AdvanceVertex()
	end
	mesh.End()
	return m
end
ST.SEA_SIZE = 480000

-- the water level here (Lua's frame), for falling in
ST.WATER_ABOVE = 48

function ST.WaterLevel(p)
	if not ST.on or not p then return nil end
	local o = ST.Frame()
	local abs = p + o
	local _, d = ST.DistrictAt(abs)
	if not d then return nil end
	local levels = ST.Levels(d, "water", abs)
	if levels then
		local below, above
		for _, z in ipairs(levels) do
			if z <= abs.z + ST.WATER_ABOVE then
				if not below or z > below then below = z end
			elseif not above or z < above then
				above = z
			end
		end
		local z = below or above
		if z then return z - o.z end
	end
	if not d.sea then return nil end
	return d.sea.z - o.z
end

-- floors under a point, from the district's ground grid (the map's teleport
-- dot: there's no Source world to trace against here)
ST.grids = {}
function ST.Grid(d, field)
	field = field or "ground"
	if not d[field] then return nil end
	local key = d.id .. "/" .. field
	local g = ST.grids[key]
	if g == nil then
		local f = file.Open(ST.DIR .. ST.map .. "/" .. d[field], "rb", "GAME")
		g = false
		if f then
			if f:Read(4) == "SGG1" then
				g = { file = f, x0 = f:ReadFloat(), y0 = f:ReadFloat(), cell = f:ReadFloat(), nx = f:ReadULong(), ny = f:ReadULong(), levels = f:ReadULong(), at = 24 + 4 }
			else
				f:Close()
			end
		end
		ST.grids[key] = g
	end
	return g or nil
end

function ST.Levels(d, field, abs)
	local g = ST.Grid(d, field)
	if not g then return nil end
	local ix, iy = math.floor((abs.x - g.x0) / g.cell), math.floor((abs.y - g.y0) / g.cell)
	if ix < 0 or iy < 0 or ix >= g.nx or iy >= g.ny then return nil end
	g.file:Seek(g.at + (iy * g.nx + ix) * g.levels * 2)
	local out = {}
	for _ = 1, g.levels do
		local v = g.file:ReadShort()
		if v ~= 32767 then out[#out + 1] = v * 2 end
	end
	return #out > 0 and out or nil
end

function ST.FloorBelow(p)
	if not ST.on then return nil end
	local o = ST.Frame()
	local abs = p + o
	local _, d = ST.DistrictAt(abs)
	local levels = d and ST.Levels(d, "ground", abs)
	if not levels then return nil end
	local best
	for _, z in ipairs(levels) do
		if z <= abs.z and (not best or z > best) then best = z end
	end
	if not best then return nil end
	return Vector(p.x, p.y, best - o.z)
end

-- go to another district (its spawn)
function ST.Travel(i)
	local d = ST.index and ST.index.districts and ST.index.districts[i]
	if not d or not (S.API and S.API.TeleportTo) then return false end
	local sp = d.spawn
	return S.API.TeleportTo(Vector(sp[1], sp[2], sp[3]) - ST.Frame(), d.heading or 0)
end

function ST.Districts() return ST.on and ST.index.districts or nil end

function ST.SetFocus(abs) ST.focus = abs end

function ST.FocusReady()
	if not ST.focus then return true end
	local cx, cy = math.floor(ST.focus.x / ST.size), math.floor(ST.focus.y / ST.size)
	for _, tile in pairs(ST.tiles) do
		if math.abs(tile.ix - cx) <= 1 and math.abs(tile.iy - cy) <= 1 and (tile.built[0] or tile.built[1]) then return true end
	end
	return false
end

function ST.TopZ()
	if ST.topZ == nil then
		local top = -math.huge
		for _, t in pairs(ST.index and ST.index.tiles or {}) do
			for _, info in pairs(t) do
				if info.hi and tonumber(info.hi[3]) then top = math.max(top, tonumber(info.hi[3])) end
			end
		end
		ST.topZ = top > -math.huge and top or false
	end
	return ST.topZ or nil
end

---------------------------------------------------------------------------
-- Skate 3's movable objects, fixed in place: drawn with their tiles, and
-- handed to the engine as entities near the skater (so their rails grind)
---------------------------------------------------------------------------
ST.PROP_NEAR = 2500
ST.PROP_PREFIX = "sgm_prop:"

function ST.LoadProps()
	local p = ST.index and ST.index.props
	ST.props, ST.propData, ST.propAt = nil, nil, nil
	if not (p and p.file and p.instances) then return end
	local f = file.Open(ST.DIR .. ST.map .. "/" .. p.file, "rb", "GAME")
	if not f then return end
	local data = f:Read(f:Size())
	f:Close()
	if not data or data:sub(1, 4) ~= "SGP1" then return end
	local n = I32(byte(data, 5, 8))
	local at, offsets = 9, {}
	for i = 1, n do
		offsets[i] = at
		at = at + 4 + I32(byte(data, at, at + 3)) * 36
	end
	ST.props, ST.propData, ST.propAt = p.instances, data, offsets
end

function ST.PropHulls(name)
	if type(name) ~= "string" or name:sub(1, #ST.PROP_PREFIX) ~= ST.PROP_PREFIX or not ST.propAt then return nil end
	local t = tonumber(name:sub(#ST.PROP_PREFIX + 1))
	local at = t and ST.propAt[t + 1]
	if not at then return nil end
	local data = ST.propData
	local n = I32(byte(data, at, at + 3)) * 9
	local flat = {}
	at = at + 4
	for k = 1, n do
		flat[k] = I32(byte(data, at, at + 3)) * POS
		at = at + 4
	end
	return { flat }, true, "a Skate 3 object"
end

function ST.PropFeed(centre, list, sig)
	if not ST.props then return end
	local o = ST.Frame()
	local ax, ay = centre.x + o.x, centre.y + o.y
	local r2 = ST.PROP_NEAR * ST.PROP_NEAR
	for i, e in ipairs(ST.props) do
		local dx, dy = e[2] - ax, e[3] - ay
		if dx * dx + dy * dy < r2 then
			local name = ST.PROP_PREFIX .. e[1]
			list[#list + 1] = { name, e[2] - o.x, e[3] - o.y, e[4] - o.z, e[5], e[6], e[7] }
			sig[#sig + 1] = "sgm_prop#" .. i
		end
	end
end

-- a streamed map whose world wasn't built on this PC: say how to get it
function ST.Missing()
	if ST.on or ST.warned then return end
	if GetGlobal2String("SkateGMStream", "") == "" then return end
	ST.warned = true
	local msg = "This map's world isn't on your PC: run the SkateGM installer with \"Generate maps\" ticked (Port Carverton) to build it."
	if chat and chat.AddText then chat.AddText(Color(255, 90, 80), "[SkateGM] ", msg) end
	print("[SkateGM] " .. msg)
end

function ST.Setup()
	local map = game.GetMap()
	if timer and timer.Simple then timer.Simple(8, ST.Missing) end
	if not ST.Load(map) then return end
	S.frameOffset = ST.Frame
	if hook and hook.Add then hook.Add("SkateGMTeleported", "skategm_stream", function() ST.Arrive() end) end
	S.viewZFar = ST.ZFAR
	S.WaterLevel = ST.WaterLevel
	ST.LoadProps()
	S.HullProviders = S.HullProviders or {}
	S.ExtraFeeds = S.ExtraFeeds or {}
	local function AddOnce(t, f) for _, g in ipairs(t) do if g == f then return end end t[#t + 1] = f end
	AddOnce(S.HullProviders, ST.PropHulls)
	AddOnce(S.ExtraFeeds, ST.PropFeed)
	if S.WrapModule then S.WrapModule() end
end

function ST.Stats()
	local tiles, built0, built1, meshes = 0, 0, 0, 0
	for _, t in pairs(ST.tiles) do
		tiles = tiles + 1
		if t.built[0] then built0 = built0 + 1 end
		if t.built[1] then built1 = built1 + 1 end
		for _, b in pairs(t.built) do for _, g in ipairs(b.groups) do meshes = meshes + #g.meshes end end
	end
	return tiles, built0, built1, meshes
end

if hook then
	hook.Add("InitPostEntity", "skategm_stream", ST.Setup)
	hook.Add("Think", "skategm_stream", ST.Think)
	hook.Add("PreDrawOpaqueRenderables", "skategm_stream", ST.Draw)
	hook.Add("ShutDown", "skategm_stream", ST.Reset)
	hook.Add("HUDPaint", "skategm_stream", ST.Paint)
	hook.Add("RenderScene", "skategm_stream", function(origin, angles, fov)
		if ST.reflecting then return end
		ST.renderOrigin, ST.renderAt, ST.viewFov = origin, RealTime(), fov
		ST.Reflect(origin, angles, fov)
	end)
	hook.Add("PostDraw2DSkyBox", "skategm_stream", ST.DrawSky)
end
if concommand then
	concommand.Add("skategm_stream_decals", function(_, _, args) ST.decalsOn = tonumber(args[1]) ~= 0 end)
	concommand.Add("skategm_stream_reflect", function(_, _, args) ST.reflectOn = tonumber(args[1]) ~= 0 end)
	concommand.Add("skategm_stream_fade", function(_, _, args) ST.fadeOn = tonumber(args[1]) ~= 0 end)
	concommand.Add("skategm_thumb_here", function()
		local eye = EyePos() + ST.Frame()
		local ang = EyeAngles()
		local line = string.format("thumb=(%.0f, %.0f, %.0f, %.1f, %.1f, 75)", eye.x, eye.y, eye.z, ang.p, ang.y)
		print("[SkateGM] map icon camera for " .. game.GetMap() .. ": " .. line)
		if SetClipboardText then SetClipboardText(line) end
	end)
	concommand.Add("skategm_stream_draw", function(_, _, args) ST.drawOn = tonumber(args[1]) ~= 0 end)
	concommand.Add("skategm_stream_budget", function(_, _, args) ST.BUDGET = (tonumber(args[1]) or 4) / 1000 end)
	concommand.Add("skategm_stream_stats", function()
		local tiles, b0, b1, meshes = ST.Stats()
		local o = ST.Frame()
		print(string.format("[SkateGM] stream %s: %d tiles, %d near built, %d far built, %d meshes, frame %d %d", tostring(ST.map), tiles, b0, b1, meshes, o.x, o.y))
		print("[SkateGM] drawn tiles", ST.lastTiles, "groups", ST.lastGroups, "eye", EyePos(), "view", S.view and S.view.origin)
		for _, t in pairs(ST.tiles) do
			if t.dist == 0 then print("[SkateGM] tile", t.ix, t.iy, "origin", t.origin, "centre", t.centre, "radius", t.radius, t.built[0] and #t.built[0].groups) end
		end
	end)
end
