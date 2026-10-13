-- Basketboard, server: the game. Uses only SkateGM.API from the skating add-on.
if not SKATEGM_MODES.Game then include("skategm_modes/sv_game.lua") end

local BB = BASKETBOARD
local G

local function Done(ply, how, now) return BB.Done(ply, how, now) end

local OUTCOMES = { basket = true, player = true, miss = true, nozone = true }

G = SKATEGM_MODES.Game(BB, {
	entry = function() return { total = 0 } end,
	resetEntry = function(e) e.total = 0 end,
	publicPlayer = function(p, e) return { total = e.total or 0 } end,
	public = function(S, t)
		t.start = { S.start.x, S.start.y, S.start.z }
		t.hoop, t.floor = S.hoop, S.hoop and Vector(S.hoop[1], S.hoop[2], S.ground) or nil
		t.yaw, t.time, t.size, t.height, t.facing, t.turn = S.yaw, S.time, S.size, S.height, S.facing, S.turn
		t.radius, t.zone = S.radius, S.zone
		t.last, t.winners = S.last, S.winners
	end,
	create = function(S, ply, m)
		local obj = type(m.hoop) == "table" and m.hoop or nil
		local spot = obj and SKATEGM_MODES.Vec(obj.pos)
		if not spot then return "place the hoop first" end
		S.start, S.yaw = SKATEGM_MODES.HostStart(ply, m)
		S.time, S.rounds = BB.ClampTime(m.time), BB.ClampRounds(m.rounds)
		S.radius, S.height = BB.ClampRadius(obj.scale), BB.ClampLift(obj.lift)
		S.zone = BB.ClampZone(obj.zone)
		S.ground = spot[3]
		S.hoop = Vector(spot[1], spot[2], S.ground + S.height)
		local yaw = tonumber(obj.yaw)
		S.facing = (yaw and yaw == yaw) and yaw % 360 or BB.Facing(S.hoop, { S.start.x, S.start.y }, 0)
	end,
	begin = function(S) for _, e in pairs(S.entries) do e.total = 0 end end,
	lobby = function(S) S.winners = nil end,
	results = function(S)
		local best, winners = -1, {}
		for _, p in ipairs(S.players) do
			local e = S.entries[G.Key(p)]
			if e.total > best then best, winners = e.total, { p:Nick() } elseif e.total == best then winners[#winners + 1] = p:Nick() end
		end
		if best <= 0 then winners = {} end
		S.winners = { names = winners, points = math.max(0, best) }
		return #winners > 0 and (table.concat(winners, " and ") .. " win" .. (#winners == 1 and "s" or "") .. " with " .. best .. " basket" .. (best == 1 and "" or "s") .. "!") or "nobody scored"
	end,
	turns = {
		live = { "turn", "finish" },
		skip = function(S, p, now) Done(p, "skipped", now) end,
		left = function(S, ply, name) S.last = { name = name, points = 0, how = "left" } end,
	},
	offSkate = { during = { "turn", "finish" }, action = function(S, p, now) Done(p, "left", now) end },
	tick = {
		turn = function(S, now)
			if now > S.deadline then
				S.phase, S.deadline = "finish", now + BB.FINISH + BB.WATCH
				G.Broadcast(now)
			end
		end,
		finish = function(S, now) if now > S.deadline then Done(S.active, "out of time", now) end end,
	},
	handlers = {
		result = function(ply, m, now)
			if not G.Live() then return end
			if not OUTCOMES[m.how] then return end
			Done(ply, m.how, now)
		end,
	},
})
local S = G.S

-- the active player's turn is over: how = "basket" (the board went in),
-- "player" (the skater did), "miss", "skipped", "out of time", "left"
BB.SCORING = { basket = true, player = true }
function BB.Done(ply, how, now)
	if S.active ~= ply or not SKATEGM_MODES.InPlay(S) or S.phase == "between" then return end
	local e = G.Entry(ply)
	local points = BB.SCORING[how] and 1 or 0
	e.total = (e.total or 0) + points
	S.last = { name = ply:Nick(), ent = ply:EntIndex(), points = points, how = how }
	G.EndTurn(now)
	if how == "basket" then G.TellGame(ply:Nick() .. " sank the board!") elseif how == "player" then G.TellGame(ply:Nick() .. " dunked themselves!") end
end
