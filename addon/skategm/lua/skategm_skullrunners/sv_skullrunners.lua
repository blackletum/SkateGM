-- Skull Runners, server: the game. Uses only SkateGM.API from the skating add-on.
if not SKATEGM_MODES.Game then include("skategm_modes/sv_game.lua") end

local SR = SKULLRUNNERS
local G, S

local function Spot(area)
	if ITEMS and ITEMS.RandomSpot then return ITEMS.RandomSpot(area, area[4]) end
	local r, a = area[4] * 0.9 * math.sqrt(math.random()), math.random() * math.pi * 2
	local x, y = area[1] + math.cos(a) * r, area[2] + math.sin(a) * r
	return { x, y, SKATEGM_MODES.Ground(x, y, area[3]) }
end

function SR.AddSkull(pos)
	S.nextSkull = (S.nextSkull or 0) + 1
	S.skulls[S.nextSkull] = pos
	return S.nextSkull
end

local function SkullCount()
	local n = 0
	for _ in pairs(S.skulls or {}) do n = n + 1 end
	return n
end

local function Countdown(S, now)
	if now > S.deadline then
		S.phase, S.deadline = "playing", now + S.time
		G.Broadcast(now)
	end
end

G = SKATEGM_MODES.Game(SR, {
	freeze = false,
	entry = function() return { skulls = 0 } end,
	resetEntry = function(e) e.skulls, e.playing, e.slot = 0, nil, nil end,
	publicPlayer = function(p, e) return { skulls = e.skulls or 0, playing = e.playing or nil, slot = e.slot } end,
	public = function(S, t)
		t.start, t.yaw, t.area = { S.start.x, S.start.y, S.start.z }, S.yaw, S.area
		t.time, t.count, t.items = S.time, S.count, S.items
		t.skulls = {}
		for id, k in pairs(S.skulls or {}) do t.skulls[#t.skulls + 1] = { id, k[1], k[2], k[3] } end
		t.slots, t.winners = S.slots, S.winners
	end,
	create = function(S, ply, m)
		local c = SKATEGM_MODES.Vec(m.centre) or (function() local p = SKATEGM_MODES.HostStart(ply, m) return { p.x, p.y, p.z } end)()
		S.start, S.yaw = SKATEGM_MODES.HostStart(ply, m)
		S.area = { c[1], c[2], c[3], SR.ClampArea(m.radius) }
		S.time, S.count, S.items = SR.ClampTime(m.time), SR.ClampSkulls(m.skulls), m.items ~= false
	end,
	begin = function(S, now)
		S.skulls, S.nextSkull, S.slots = {}, 0, #S.players
		local spots = ITEMS and ITEMS.Spread and ITEMS.Spread(S.area, S.area[4], S.count) or nil
		for i = 1, S.count do SR.AddSkull(spots and spots[i] or Spot(S.area)) end
		for i, p in ipairs(S.players) do
			local e = G.Entry(p)
			e.skulls, e.playing, e.slot, e.dropAt = 0, true, i, nil
		end
		S.phase, S.deadline = "countdown", now + SR.COUNTDOWN
		G.Broadcast(now)
	end,
	lobby = function(S) S.skulls, S.winners, S.slots = nil, nil, nil end,
	results = function(S)
		local best, names = -1, {}
		for _, p in ipairs(S.players) do
			local e = G.Entry(p)
			if e.playing then
				if e.skulls > best then best, names = e.skulls, { p:Nick() } elseif e.skulls == best then names[#names + 1] = p:Nick() end
			end
		end
		S.winners = { names = names, skulls = math.max(0, best) }
		return #names > 0 and (table.concat(names, " and ") .. " win" .. (#names == 1 and "s" or "") .. " with " .. best .. " skulls!") or "nobody's left"
	end,
	think = function(S)
		if ITEMS and ITEMS.server then
			ITEMS.server.Sync(SR.mode, S, { on = S.items, centre = Vector(S.area[1], S.area[2], S.area[3]), radius = S.area[4] })
		end
	end,
	tick = {
		countdown = Countdown,
		playing = function(S, now) if now > S.deadline then G.Results(now) end end,
	},
	handlers = {
		grab = function(ply, m, now)
			if S.phase ~= "playing" then return end
			local e = G.IndexOf(ply) and G.Entry(ply)
			local id = tonumber(m.id)
			local k = id and S.skulls[id]
			if not (e and e.playing and k) then return end
			local at = SkateGMSkaterAbs(ply)
			if at:Distance(Vector(k[1], k[2], k[3] + SR.FLOAT)) > SR.TOUCH_CHECK then return end
			S.skulls[id] = nil
			e.skulls = e.skulls + 1
			if SkullCount() < S.count then SR.AddSkull(Spot(S.area)) end
			G.Broadcast(now)
		end,
		bailed = function(ply, m, now) SR.Drop(ply, now) end,
	},
})
S = G.S

-- someone bailed (an item's hit or their own): some of their skulls drop around them
function SR.Drop(ply, now)
	local e = G.IndexOf(ply) and G.Entry(ply)
	if S.phase ~= "playing" or not (e and e.playing) then return end
	if (e.dropAt or 0) > now then return end
	e.dropAt = now + 2
	local n = math.min(e.skulls, SR.DROP)
	if n <= 0 then return end
	e.skulls = e.skulls - n
	local at = SkateGMSkaterAbs(ply)
	for i = 1, n do
		local a = (i / n + math.random() * 0.3) * math.pi * 2
		local x, y = at.x + math.cos(a) * SR.DROP_SPREAD, at.y + math.sin(a) * SR.DROP_SPREAD
		SR.AddSkull({ x, y, SKATEGM_MODES.Ground(x, y, at.z) })
	end
	G.TellGame(string.format("%s bailed and dropped %d skull%s!", ply:Nick(), n, n == 1 and "" or "s"))
	G.Broadcast(now)
end
