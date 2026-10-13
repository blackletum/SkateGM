-- Melon King, server: the game, the melon and everyone's time with it. Uses
-- only SkateGM.API from the skating add-on.
if not SKATEGM_MODES.Game then include("skategm_modes/sv_game.lua") end

local Skating, Vec = SKATEGM_MODES.Skating, SKATEGM_MODES.Vec
local GM, G

local function Entry(ply) return GM.IndexOf(ply) and GM.Entry(ply) or nil end
local function Playing(ply) local e = Entry(ply) return e ~= nil and e.playing end

local function V(t) return Vector(t[1], t[2], t[3]) end

-- where a player's skater is, as their pose updates tell the server
local function SkaterPos(ply) return IsValid(ply) and ply.SkateGMHips or nil end
MELON.SkaterPos = SkaterPos

---------------------------------------------------------------------------
-- the melon
---------------------------------------------------------------------------
local function RemoveMelon()
	if IsValid(G.melonEnt) then G.melonEnt:Remove() end
	G.melonEnt, G.lostSince = nil, nil
end

local function MakeMelon(pos, vel)
	RemoveMelon()
	local e = ents.Create("prop_physics")
	if not IsValid(e) then return nil end
	e:SetModel(MELON.MODEL)
	SkateGMPlace(e, pos)
	e:SetAngles(Angle(0, math.random(0, 359), 0))
	e.SkateGMMelon = true
	e:SetNWBool("SkateGMMelon", true)
	-- (a watermelon is breakable: falling into the area it smashed on landing)
	e:SetKeyValue("physdamagescale", "0")
	e:SetKeyValue("minhealthdmg", "999999")
	e:SetKeyValue("spawnflags", "256")
	e:Spawn()
	e:SetCollisionGroup(COLLISION_GROUP_WEAPON)
	local phys = e:GetPhysicsObject()
	if IsValid(phys) then
		phys:Wake()
		if vel then phys:SetVelocity(vel) end
	end
	G.melonEnt = e
	return e
end

-- a random spot on the ground inside the area, the melon falling onto it.
-- Searched from the area's own height (from above it found roofs, and a
-- start inside the sky's solid found nothing): up to the ceiling or the drop
-- height, then down from there to the ground.
function MELON.DropSpot(area)
	local mask = MASK_SOLID
	for _ = 1, 16 do
		local a, r = math.random() * math.pi * 2, math.sqrt(math.random()) * area[4] * 0.8
		local x, y = area[1] + math.cos(a) * r, area[2] + math.sin(a) * r
		local from = Vector(x, y, area[3] + 48)
		if not (SkateGMTraceWorld or util.TraceLine)({ start = from, endpos = from + Vector(0, 0, 1), mask = mask }).StartSolid then
			local up = (SkateGMTraceWorld or util.TraceLine)({ start = from, endpos = from + Vector(0, 0, MELON.DROP_HEIGHT), mask = mask })
			local top = up.HitPos - Vector(0, 0, 16)
			local down = (SkateGMTraceWorld or util.TraceLine)({ start = top, endpos = top - Vector(0, 0, 4096), mask = mask })
			if down.Hit and not down.StartSolid and not down.HitSky and down.HitNormal.z > 0.5 and down.HitPos.z > area[3] - 1024 then
				return top
			end
		end
	end
	return Vector(area[1], area[2], area[3] + 64)
end

local function DropFromSky(now)
	G.dropTime = nil
	MakeMelon(MELON.DropSpot(G.area))
	GM.TellGame("the melon is loose!")
	GM.Broadcast(now)
end

local function Seize(ply, from, now)
	RemoveMelon()
	G.king, G.kingSince = ply, now
	G.kingFrom, G.kingFromAt = from, from and now or nil
	G.dropper, G.dropAt = nil, nil
	GM.TellGame(ply:Nick() .. " seized the melon!")
	GM.Broadcast(now)
end
MELON.Seize = Seize

local function Drop(now, pos, why)
	local king = G.king
	if not king then return end
	local valid = IsValid(king)
	local name = GM.Name(king)
	if name == "?" then name = "the Melon King" end
	G.king, G.kingSince, G.kingFrom = nil, nil, nil
	G.dropper, G.dropAt = valid and king or nil, now
	pos = pos or SkaterPos(king) or G.kingPos or Vector(G.area[1], G.area[2], G.area[3])
	MakeMelon(pos + Vector(0, 0, 24), Vector(math.Rand(-60, 60), math.Rand(-60, 60), 180))
	GM.TellGame(name .. " " .. (why or "bailed") .. " and dropped the melon!")
	GM.Broadcast(now)
end
MELON.Drop = Drop

local function PlayingCount()
	local n = 0
	for _, p in ipairs(G.players) do if Playing(p) then n = n + 1 end end
	return n
end

---------------------------------------------------------------------------
-- touches (each skater's own game sees them; the server checks they're near)
---------------------------------------------------------------------------
local SLACK = 96 -- network lag: how far off the server's idea of a skater may be

function MELON.Grab(ply, now)
	if G.phase ~= "playing" or IsValid(G.king) or not IsValid(G.melonEnt) then return false end
	if not (Playing(ply) and Skating(ply)) then return false end
	if ply == G.dropper and now - (G.dropAt or 0) < MELON.DROP_LOCK then return false end
	local pos = SkaterPos(ply)
	if not pos or pos:Distance(SkateGMEntAbs(G.melonEnt)) > MELON.GRAB_RADIUS + SLACK then return false end
	Seize(ply, nil, now)
	return true
end

function MELON.Steal(ply, target, now)
	if G.phase ~= "playing" or target ~= G.king or not IsValid(target) or target == ply then return false end
	if not (Playing(ply) and Skating(ply)) then return false end
	if now - (G.kingSince or now) < MELON.HOLD_GRACE then return false end
	if ply == G.kingFrom and now - (G.kingFromAt or 0) < MELON.NO_TAGBACK then return false end
	local a, b = SkaterPos(ply), SkaterPos(target)
	if not (a and b) or a:Distance(b) > MELON.STEAL_RADIUS + SLACK then return false end
	Seize(ply, target, now)
	return true
end

function MELON.Bail(ply, pos, now)
	if G.phase ~= "playing" or ply ~= G.king then return false end
	local here = SkaterPos(ply)
	local p = pos and V(pos)
	if not p or (here and p:Distance(here) > 200) then p = here end
	Drop(now, p, "bailed")
	return true
end

local function Host(ply) return GM.Host(ply) end
local handlers = {}

function handlers.settings(ply, m, now)
	if not Host(ply) then return GM.Tell(ply, "only the host can change the settings") end
	if G.phase ~= "lobby" then return GM.Tell(ply, "settings can be changed between games") end
	G.target = MELON.ClampTarget(m.target or G.target)
	if m.radius then G.area[4] = MELON.ClampArea(m.radius) end
	GM.Broadcast(now)
	GM.TellGame(string.format("hold the melon for %d s to win; the area is %d units across", G.target, G.area[4] * 2))
end

function handlers.grab(ply, m, now) MELON.Grab(ply, now) end

function handlers.steal(ply, m, now)
	local target
	for _, p in ipairs(G.players or {}) do if p:EntIndex() == tonumber(m.target) then target = p end end
	MELON.Steal(ply, target, now)
end

function handlers.bail(ply, m, now) MELON.Bail(ply, m.pos, now) end

function handlers.outside(ply, m, now)
	if G.phase == "playing" and ply == G.king then Drop(now, MELON.DropSpot(G.area), "left the area") end
end

GM = SKATEGM_MODES.Game(MELON, {
	freeze = false,
	maxPlayers = MELON.MAX_PLAYERS,
	openText = "a game is already set up: join it",
	noGameText = "no game set up: !melon create starts one",
	entry = function() return { held = 0 } end,
	resetEntry = function(e) e.playing, e.held = nil, 0 end,
	publicPlayer = function(p, e) return { held = e.held or 0, playing = e.playing } end,
	public = function(S, t, now)
		t.start, t.yaw, t.area, t.target = S.start, S.yaw or 0, S.area, S.target
		t.king = IsValid(S.king) and S.king:EntIndex() or nil
		t.kingFor = IsValid(S.king) and (now - S.kingSince) or nil
		t.from = IsValid(S.kingFrom) and S.kingFrom:EntIndex() or nil
		t.melon = IsValid(S.melonEnt) and S.melonEnt:EntIndex() or nil
		t.dropper = IsValid(S.dropper) and S.dropper:EntIndex() or nil
		t.dropLock = S.dropAt and math.max(0, S.dropAt + MELON.DROP_LOCK - now) or nil
		t.dropIn = S.dropTime and math.max(0, S.dropTime - now) or nil
		t.winner = S.winner
	end,
	create = function(S, ply, m)
		local p = Vec(m.pos)
		if not p then return true end
		local c = Vec(m.centre) or p
		S.start, S.yaw = p, math.NormalizeAngle(tonumber(m.yaw) or 0)
		S.area = { c[1], c[2], c[3], MELON.ClampArea(m.radius) }
		S.target = MELON.ClampTarget(m.target)
		S.items = m.items == true
	end,
	begin = function(S, now)
		local n = 0
		for _, p in ipairs(S.players) do
			local e = GM.Entry(p)
			e.playing = Skating(p) or nil
			e.held = 0
			if e.playing then n = n + 1 else GM.Tell(p, "not in Skater mode yet: you sit this one out") end
		end
		if n < 2 then return "Melon King needs at least two skaters in Skater mode" end
		S.phase, S.deadline, S.winner = "countdown", now + MELON.COUNTDOWN, nil
		GM.Broadcast(now)
	end,
	lobby = function(S)
		RemoveMelon()
		S.winner, S.king, S.kingFrom, S.dropper, S.dropAt, S.dropTime = nil, nil, nil, nil, nil, nil
	end,
	stop = function() RemoveMelon() end,
	results = function(S, now, winner)
		RemoveMelon()
		S.king = nil
		S.winner = winner and { name = winner:Nick(), ent = winner:EntIndex() } or nil
		return winner and (winner:Nick() .. " is the Melon King!") or "nobody won"
	end,
	leaving = function(S, ply, now) if S.king == ply then Drop(now, nil, "left") end end,
	removed = function(S, ply, now)
		if S.kingFrom == ply then S.kingFrom = nil end
		if S.dropper == ply then S.dropper = nil end
		if S.phase == "playing" and PlayingCount() < 2 then
			local last
			for _, p in ipairs(S.players) do if Playing(p) then last = p end end
			GM.Results(now, last)
			return true
		end
	end,
	think = function(S)
		if ITEMS and ITEMS.server and S.area then
			ITEMS.server.Sync(MELON.mode, S, { on = S.items, centre = Vector(S.area[1], S.area[2], S.area[3]), radius = S.area[4] })
		end
	end,
	refresh = { during = { "playing" }, every = 0.5 },
	tick = {
		countdown = function(S, now)
			if now >= S.deadline then
				S.phase, S.deadline = "playing", nil
				S.dropTime, S.lastTick = now + MELON.FIRST_DROP, now
				GM.Broadcast(now)
			end
		end,
		playing = function(S, now)
			local dt = math.max(0, now - (S.lastTick or now))
			S.lastTick = now
			local king = S.king
			if IsValid(king) then
				S.kingPos = SkaterPos(king) or S.kingPos
				if not Skating(king) then
					Drop(now, nil, "left Skater mode")
				else
					local e = Entry(king)
					-- the clock only runs inside the area
					if e and MELON.InArea(S.area, SkaterPos(king)) then
						e.held = (e.held or 0) + dt
						if e.held >= S.target then return GM.Results(now, king) end
					end
				end
			elseif S.dropTime then
				if now >= S.dropTime then DropFromSky(now) end
			elseif not IsValid(S.melonEnt) then
				S.dropTime = now + 1
			else
				local pos = SkateGMEntAbs(S.melonEnt)
				local out = not MELON.InArea(S.area, pos) or pos.z < S.area[3] - 2048
				if out then
					S.lostSince = S.lostSince or now
					if now - S.lostSince > MELON.LOST_AFTER then
						RemoveMelon()
						S.dropTime = now + 0.5
						GM.TellGame("the melon rolled away: a new one drops in")
					end
				else
					S.lostSince = nil
				end
			end
		end,
		results = function(S, now) if now >= S.deadline then GM.ToLobby(now) end end,
	},
	handlers = handlers,
})
G = GM.S
MELON.Think = GM.Tick

-- nobody carries the melon off with the physgun, gravity gun or toolgun
local function NotTheMelon(_, ent) if IsValid(ent) and ent.SkateGMMelon then return false end end
hook.Add("PhysgunPickup", "skategm_melon", NotTheMelon)
hook.Add("GravGunPickupAllowed", "skategm_melon", NotTheMelon)
hook.Add("GravGunPunt", "skategm_melon", NotTheMelon)
hook.Add("CanTool", "skategm_melon", function(_, tr) if tr and IsValid(tr.Entity) and tr.Entity.SkateGMMelon then return false end end)
hook.Add("CanPlayerUnfreeze", "skategm_melon", NotTheMelon)
hook.Add("EntityTakeDamage", "skategm_melon", function(ent) if IsValid(ent) and ent.SkateGMMelon then return true end end)
