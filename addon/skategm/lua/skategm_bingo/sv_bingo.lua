if not SKATEGM_MODES.Game then include("skategm_modes/sv_game.lua") end

local Skating = SKATEGM_MODES.Skating
local GM, G

local handlers = {}

function handlers.done(ply, m, now)
	if G.phase ~= "playing" then return end
	local e = GM.IndexOf(ply) and GM.Entry(ply)
	local i = tonumber(m.cell)
	if not e or not i or i ~= math.floor(i) or not G.card[i] or G.card[i] == "free" or e.marks[i] then return end
	if not e.playing then e.playing = true end
	e.marks[i] = true
	local task = BINGO.BY_ID[G.card[i]]
	GM.TellGame(string.format("%s: %s (%d/%d)", ply:Nick(), task and task.label or G.card[i], BINGO.Count(e.marks, G.card), #G.card))
	if BINGO.Won(e.marks, G.card, G.full) then return GM.Results(now, ply, G.full and "full card" or "BINGO") end
	GM.Broadcast(now)
end

GM = SKATEGM_MODES.Game(BINGO, {
	freeze = false,
	maxPlayers = BINGO.MAX_PLAYERS,
	openText = "a game is already set up: join it",
	noGameText = "no game set up",
	canJoin = function() end,
	joined = function(S, ply) if S.phase == "playing" and Skating(ply) then GM.Entry(ply).playing = true end end,
	entry = function() return { marks = {} } end,
	resetEntry = function(e) e.playing, e.marks = nil, {} end,
	publicPlayer = function(p, e, S)
		local marks = {}
		for i in pairs(e.marks or {}) do marks[#marks + 1] = i end
		table.sort(marks)
		return { playing = e.playing, marks = marks, count = S.card and BINGO.Count(e.marks or {}, S.card) or 0 }
	end,
	public = function(S, t)
		t.card, t.full, t.free, t.time = S.card, S.full, S.free, S.time
		t.winner = S.winner
	end,
	create = function(S, ply, m)
		S.time, S.full, S.free = BINGO.ClampTime(m.time), m.full == true, m.free ~= false
	end,
	begin = function(S, now)
		S.card = BINGO.Deal(math.random, S.free)
		for _, p in ipairs(S.players) do
			local e = GM.Entry(p)
			e.playing, e.marks = Skating(p) or nil, {}
		end
		S.phase, S.deadline, S.winner = "countdown", now + BINGO.COUNTDOWN, nil
		GM.Broadcast(now)
	end,
	lobby = function(S) S.winner = nil end,
	results = function(S, now, winner, why)
		if not winner then
			local best, bestN
			for _, p in ipairs(S.players) do
				local e = GM.Entry(p)
				if e.playing then
					local n = BINGO.Count(e.marks, S.card)
					if not bestN or n > bestN then best, bestN = p, n end
				end
			end
			winner = best
		end
		S.winner = winner and { name = winner:Nick(), ent = winner:EntIndex() } or nil
		return winner and (winner:Nick() .. " wins Trick Bingo" .. (why and (" (" .. why .. ")") or "")) or "nobody played"
	end,
	tick = {
		countdown = function(S, now)
			if now >= S.deadline then
				S.phase, S.deadline = "playing", now + S.time
				GM.Broadcast(now)
			end
		end,
		playing = function(S, now) if now >= S.deadline then GM.Results(now, nil, "time's up: most squares") end end,
		results = function(S, now) if now >= S.deadline then GM.ToLobby(now) end end,
	},
	handlers = handlers,
})
G = GM.S
BINGO.Think = GM.Tick
