-- Bullseye, server: the game. Uses only SkateGM.API from the skating add-on.
if not SKATEGM_MODES.Game then include("skategm_modes/sv_game.lua") end

local BE = BULLSEYE
local G

local function Shot(ply, pos, how, now) return BE.Shot(ply, pos, how, now) end

G = SKATEGM_MODES.Game(BE, {
	entry = function() return { total = 0 } end,
	resetEntry = function(e) e.total = 0 end,
	publicPlayer = function(p, e) return { total = e.total or 0 } end,
	public = function(S, t)
		t.start = { S.start.x, S.start.y, S.start.z }
		t.target, t.yaw, t.time, t.size, t.width, t.zone = S.target, S.yaw, S.time, S.size, S.width, S.zone
		t.last, t.shots, t.winners = S.last, S.shots, S.winners
	end,
	create = function(S, ply, m)
		local target = SKATEGM_MODES.Vec(m.target)
		if not target then return "place the target first" end
		S.start, S.yaw = SKATEGM_MODES.HostStart(ply, m)
		S.target = target
		S.time, S.rounds = BE.ClampTime(m.time), BE.ClampRounds(m.rounds)
		S.size = (m.size == "small" or m.size == "large") and m.size or BE.SIZE_DEFAULT
		S.width = m.width and BE.ClampWidth(m.width) or BE.RingWidth(S.size)
		S.zone = BE.ClampZone(m.zone)
	end,
	begin = function(S)
		for _, e in pairs(S.entries) do e.total = 0 end
		S.shots = {}
	end,
	lobby = function(S) S.shots, S.winners = nil, nil end,
	results = function(S)
		local best, winners = -1, {}
		for _, p in ipairs(S.players) do
			local e = S.entries[G.Key(p)]
			if e.total > best then best, winners = e.total, { p:Nick() } elseif e.total == best then winners[#winners + 1] = p:Nick() end
		end
		S.winners = { names = winners, points = math.max(0, best) }
		return #winners > 0 and (table.concat(winners, " and ") .. " win" .. (#winners == 1 and "s" or "") .. " with " .. math.max(0, best) .. " points!") or "nobody scored"
	end,
	turns = {
		live = { "shot", "finish" },
		newRound = function(S) S.shots = {} end,
		skip = function(S, p, now) Shot(p, nil, "skipped", now) end,
		left = function(S, ply, name) S.last = { name = name, points = 0, how = "left" } end,
	},
	offSkate = { during = { "shot", "finish" }, action = function(S, p, now) Shot(p, nil, "left Skater mode", now) end },
	tick = {
		shot = function(S, now)
			if now > S.deadline then
				S.phase, S.deadline = "finish", now + BE.FINISH
				G.Broadcast(now)
			end
		end,
		finish = function(S, now) if now > S.deadline then Shot(S.active, nil, "out of time", now) end end,
	},
	handlers = {
		landed = function(ply, m, now)
			if not G.Live() then return end
			if m.nozone then return Shot(ply, nil, "nozone", now) end
			Shot(ply, m.bailed and nil or m.pos, m.bailed and "bailed" or "landed", now)
		end,
	},
})
local S = G.S

-- the active player's shot: landed at pos, or bailed / never landed (pos nil)
function BE.Shot(ply, pos, how, now)
	if S.active ~= ply or not SKATEGM_MODES.InPlay(S) then return end
	local e = G.Entry(ply)
	local points, ring = 0, nil
	local x, y, z = pos and tonumber(pos[1]), pos and tonumber(pos[2]), pos and tonumber(pos[3])
	if x and y and z and x == x and y == y then
		points, ring = BE.Score(S.target, x, y, S.width)
	else
		x, y, z = nil, nil, nil
	end
	e.total = (e.total or 0) + points
	S.last = { name = ply:Nick(), ent = ply:EntIndex(), points = points, ring = ring, how = how }
	S.shots = S.shots or {}
	if x then S.shots[#S.shots + 1] = { ent = ply:EntIndex(), x = x, y = y, z = z, points = points } end
	G.EndTurn(now)
end
