-- Ball Battle, server: the game. Uses only SkateGM.API from the skating add-on.
if not SKATEGM_MODES.Game then include("skategm_modes/sv_game.lua") end

local BB = BALLBATTLE
local G, S

local function Alive()
	local out = {}
	for _, p in ipairs(S.players) do
		local e = G.Entry(p)
		if e and e.playing and not e.out then out[#out + 1] = p end
	end
	return out
end

local function Playing(ply)
	local e = G.IndexOf(ply) and G.Entry(ply)
	if S.phase ~= "playing" or not (e and e.playing) or e.out then return nil end
	return e
end

G = SKATEGM_MODES.Game(BB, {
	freeze = false,
	minPlayers = 2,
	entry = function() return { balls = 0 } end,
	resetEntry = function(e) e.balls, e.playing, e.out, e.slot = 0, nil, nil, nil end,
	publicPlayer = function(p, e) return { balls = e.balls or 0, playing = e.playing or nil, out = e.out or nil, slot = e.slot } end,
	public = function(S, t)
		t.start, t.yaw, t.area = { S.start.x, S.start.y, S.start.z }, S.yaw, S.area
		t.time, t.balls, t.items = S.time, S.balls, S.items
		t.slots, t.winners = S.slots, S.winners
	end,
	create = function(S, ply, m)
		local c = SKATEGM_MODES.Vec(m.centre) or (function() local p = SKATEGM_MODES.HostStart(ply, m) return { p.x, p.y, p.z } end)()
		S.start, S.yaw = SKATEGM_MODES.HostStart(ply, m)
		S.area = { c[1], c[2], c[3], BB.ClampArea(m.radius) }
		S.time, S.balls, S.items = BB.ClampTime(m.time), BB.ClampBalls(m.balls), m.items ~= false
	end,
	begin = function(S, now)
		S.slots = #S.players
		for i, p in ipairs(S.players) do
			local e = G.Entry(p)
			e.balls, e.playing, e.out, e.slot, e.popAt = S.balls, true, nil, i, nil
		end
		S.phase, S.deadline = "countdown", now + BB.COUNTDOWN
		G.Broadcast(now)
	end,
	lobby = function(S) S.winners, S.slots = nil, nil end,
	results = function(S)
		local best, names = -1, {}
		for _, p in ipairs(Alive()) do
			local b = G.Entry(p).balls
			if b > best then best, names = b, { p:Nick() } elseif b == best then names[#names + 1] = p:Nick() end
		end
		S.winners = { names = names }
		return #names > 0 and (table.concat(names, " and ") .. " win" .. (#names == 1 and "s" or "") .. " Ball Battle!") or "nobody's left"
	end,
	removed = function(S, ply, now)
		if SKATEGM_MODES.InPlay(S) and #Alive() <= 1 then G.Results(now) return true end
	end,
	think = function(S)
		if ITEMS and ITEMS.server then
			ITEMS.server.Sync(BB.mode, S, { on = S.items, centre = Vector(S.area[1], S.area[2], S.area[3]), radius = S.area[4],
				onHit = function(victim) BB.Pop(victim, "hit", CurTime()) end,
				canPlay = function(ply, game) local e = game and game.entries and game.entries[G.Key(ply)] return e ~= nil and e.playing and not e.out end })
		end
	end,
	tick = {
		countdown = function(S, now)
			if now > S.deadline then
				S.phase, S.deadline = "playing", now + S.time
				G.Broadcast(now)
			end
		end,
		playing = function(S, now) if now > S.deadline then G.Results(now) end end,
	},
	handlers = {
		bailed = function(ply, m, now) BB.Pop(ply, "bail", now) end,
		-- out of bounds for too long: out of the game
		outside = function(ply, m, now)
			local e = Playing(ply)
			if not e then return end
			e.balls, e.out = 0, true
			G.TellGame(ply:Nick() .. " went out of bounds: out!")
			if #Alive() <= 1 then return G.Results(now) end
			G.Broadcast(now)
		end,
	},
})
S = G.S

function BB.Pop(ply, why, now)
	local e = Playing(ply)
	if not e then return false end
	if (e.popAt or 0) > now then return false end
	e.popAt = now + BB.GRACE
	e.balls = e.balls - 1
	if e.balls <= 0 then
		e.balls, e.out = 0, true
		G.TellGame(ply:Nick() .. " lost their last ball: out!")
		if #Alive() <= 1 then return G.Results(now) end
	end
	G.Broadcast(now)
	return true
end
