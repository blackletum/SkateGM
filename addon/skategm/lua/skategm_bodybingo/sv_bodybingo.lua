-- Body Bingo, server: the game. Uses only SkateGM.API from the skating add-on.
if not SKATEGM_MODES.Game then include("skategm_modes/sv_game.lua") end

local BB = BODYBINGO
local G, S

local handlers = {}

function handlers.hurt(ply, m, now)
	if S.phase ~= "playing" then return end
	local e = G.IndexOf(ply) and G.Entry(ply)
	local level = tonumber(m.level)
	if not (e and e.playing and type(m.part) == "string" and level) then return end
	local ticked = BB.Ticks(S.card, e.marks, m.part, math.floor(level))
	if #ticked == 0 then return end
	for _, i in ipairs(ticked) do e.marks[i] = true end
	local sq = S.card[ticked[1]]
	local part = HOM and HOM.PART and HOM.PART[sq.part]
	local lv = HOM and HOM.LEVELS and HOM.LEVELS[sq.level]
	G.TellGame(string.format("%s: %s %s (%d/%d)", ply:Nick(), part and part.name or sq.part, lv and lv.name or "", BB.Count(e.marks, S.card), #S.card))
	if BB.Won(e.marks, S.card, S.full) then return G.Results(now, ply, S.full and "full card" or "BINGO") end
	G.Broadcast(now)
end

G = SKATEGM_MODES.Game(BB, {
	freeze = false,
	entry = function() return { marks = {} } end,
	resetEntry = function(e) e.playing, e.marks = nil, {} end,
	publicPlayer = function(p, e, S)
		local marks = {}
		for i in pairs(e.marks or {}) do marks[#marks + 1] = i end
		table.sort(marks)
		return { playing = e.playing or nil, marks = marks, count = S.card and BB.Count(e.marks or {}, S.card) or 0 }
	end,
	public = function(S, t)
		t.card, t.full, t.time, t.pain = S.card, S.full, S.time, S.pain
		t.start, t.yaw = S.start, S.yaw
		t.winner = S.winner
	end,
	create = function(S, ply, m)
		local p, yaw = SKATEGM_MODES.HostStart(ply, m)
		S.start, S.yaw = { p.x, p.y, p.z }, yaw
		S.time, S.full = BB.ClampTime(m.time), m.full == true
		S.pain = HOM and HOM.PainScale and HOM.PainScale(m.pain) or 1
	end,
	begin = function(S, now)
		if not (HOM and HOM.PARTS) then return "Body Bingo needs Hall of Meat's injuries (skategm_hom)" end
		S.card = BB.Deal(HOM.PARTS)
		for _, e in pairs(S.entries) do e.playing, e.marks = true, {} end
		S.phase, S.deadline, S.winner = "countdown", now + BB.COUNTDOWN, nil
		G.Broadcast(now)
	end,
	lobby = function(S) S.winner, S.card = nil, nil end,
	results = function(S, now, winner, why)
		if not winner then
			local best, bestN
			for _, p in ipairs(S.players) do
				local e = G.Entry(p)
				if e.playing then
					local n = BB.Count(e.marks, S.card)
					if not bestN or n > bestN then best, bestN = p, n end
				end
			end
			winner = best
		end
		S.winner = winner and { name = winner:Nick(), ent = winner:EntIndex() } or nil
		return winner and (winner:Nick() .. " wins Body Bingo" .. (why and (" (" .. why .. ")") or "")) or "nobody played"
	end,
	tick = {
		countdown = function(S, now)
			if now > S.deadline then
				S.phase, S.deadline = "playing", now + S.time
				G.Broadcast(now)
			end
		end,
		playing = function(S, now) if now > S.deadline then G.Results(now, nil, "time's up: most squares") end end,
	},
	handlers = handlers,
})
S = G.S

-- LB + X while playing: back to the start
BB.mode:RespawnAt(function(ply)
	if not S.start then return nil end
	local i = G.IndexOf(ply) or 1
	local s = BB.Slot(S.start, S.yaw, i, #S.players)
	return Vector(s[1], s[2], s[3]), S.yaw
end)
