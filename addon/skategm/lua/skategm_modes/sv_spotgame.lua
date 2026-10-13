-- A spot game, server: take turns from one spot, the best single turn wins.
-- Own the Spot and Steezus Stint are both this; a mode passes its table (limits
-- from its sh file) and its wording.
if not SKATEGM_MODES.Game then include("skategm_modes/sv_game.lua") end

function SKATEGM_MODES.SpotServer(T, spec)
	spec = spec or {}
	local G, S

	-- record the active player's turn (unless they never got going)
	local function EndTurn(now, reason, record)
		local p = S.active
		local e = IsValid(p) and G.Entry(p)
		if record and e then
			local score = math.Clamp(math.floor(S.live or 0), 0, T.MAX_SCORE)
			e.turns[#e.turns + 1] = score
			e.best = math.max(e.best, score)
			e.total = e.total + score
			S.last = { name = p:Nick(), ent = p:EntIndex(), score = score, reason = reason }
			S.lastKey = G.Key(p)
		else
			S.last = { name = IsValid(p) and p:Nick() or "?", ent = IsValid(p) and p:EntIndex() or nil, score = 0, reason = reason, skipped = true }
			S.lastKey = nil
		end
		G.EndTurn(now)
	end

	-- a late final score from the player whose turn just ended replaces the last live one
	local function LateFinal(ply, score, now)
		if S.phase ~= "between" or not S.lastKey or S.lastKey ~= G.Key(ply) then return end
		local e = S.entries[S.lastKey]
		score = math.Clamp(math.floor(score or 0), 0, T.MAX_SCORE)
		local old = e.turns[#e.turns]
		e.turns[#e.turns] = score
		e.total = e.total - old + score
		e.best = 0
		for _, v in ipairs(e.turns) do e.best = math.max(e.best, v) end
		S.last.score = score
		S.lastKey = nil
		G.Broadcast(now)
	end

	local function Host(ply) return G.Host(ply) end
	local handlers = {}

	function handlers.settings(ply, m, now)
		if not Host(ply) then return G.Tell(ply, "only the host can change the settings") end
		if S.phase ~= "lobby" then return G.Tell(ply, "settings can be changed before the start") end
		if m.turn then S.turn = T.ClampTurn(m.turn) end
		if m.rounds then S.rounds = T.ClampRounds(m.rounds) end
		G.Broadcast(now)
		G.TellGame(string.format("turns are %d s, %d round%s", S.turn, S.rounds, S.rounds == 1 and "" or "s"))
	end

	function handlers.spot(ply, m, now)
		if not Host(ply) then return G.Tell(ply, "only the host can move the spot") end
		if S.phase ~= "lobby" then return G.Tell(ply, "the spot can be moved before the start") end
		S.spot, S.yaw = SkateGMAbsPos and SkateGMAbsPos(ply) or ply:GetPos(), ply:EyeAngles().y
		G.Broadcast(now)
		G.TellGame("the spot moved to where " .. ply:Nick() .. " is")
	end

	function handlers.live(ply, m, now)
		if S.phase ~= "turn" or S.active ~= ply then return end
		S.live = math.Clamp(tonumber(m.score) or 0, 0, T.MAX_SCORE)
	end

	function handlers.bailed(ply, m, now)
		if not S.bailEnds or S.phase ~= "turn" or S.active ~= ply then return end
		S.live = math.Clamp(tonumber(m.score) or S.live or 0, 0, T.MAX_SCORE)
		EndTurn(now, "bailed", true)
	end

	function handlers.final(ply, m, now) LateFinal(ply, tonumber(m.score), now) end

	G = SKATEGM_MODES.Game(T, {
		resultsPhase = "final",
		afterResults = "stop",
		openText = "a challenge is already running",
		noGameText = "no challenge is open: !" .. T.mode.id .. " create starts one",
		canJoin = function(S) if S.phase == "final" then return "this challenge is finishing" end end,
		joinedText = function(S) return S.phase ~= "lobby" and " (from the next turn in the order)" or "" end,
		-- people who left keep their result in the standings
		keepLeft = function() return true end,
		entry = function() return { best = 0, total = 0, turns = {} } end,
		resetEntry = function(e) e.best, e.total, e.turns = 0, 0, {} end,
		publicPlayer = function(p, e) return { best = e.best, total = e.total, turns = e.turns and #e.turns } end,
		public = function(S, t)
			t.spot = { S.spot.x, S.spot.y, S.spot.z }
			t.yaw, t.turn, t.index, t.bailEnds = S.yaw, S.turn, S.index, S.bailEnds
			t.live = S.live or 0
			t.last = S.last
			t.winner = S.winner
			t.gone = {}
			for _, e in pairs(S.entries) do
				if e.left then t.gone[#t.gone + 1] = { name = e.name, best = e.best, total = e.total } end
			end
		end,
		create = function(S, ply, m)
			S.spot, S.yaw = SKATEGM_MODES.HostStart(ply, m)
			S.turn, S.rounds = T.ClampTurn(m.turn), T.ClampRounds(m.rounds)
			S.bailEnds = m.bailEnds ~= false
		end,
		lobby = function(S) S.lastKey, S.winner, S.live = nil, nil, 0 end,
		results = function(S)
			local best, who = -1, nil
			for _, e in pairs(S.entries) do
				if #e.turns > 0 and e.best > best then best, who = e.best, e.name end
			end
			S.winner = who and { name = who, score = best } or nil
			if who then return string.format(spec.winner or "%s wins with %s!", who, string.Comma(math.floor(best))) end
			return "nobody set a score"
		end,
		refresh = { during = { "turn" }, every = 0.5 },
		turns = {
			shared = true,
			lobbyRound = 1,
			time = function(S) return S.turn end,
			skipText = " couldn't get into Skater mode in time: skipped",
			start = function(S) S.live = 0 end,
			go = function(S) S.live = 0 end,
			skip = function(S, p, now) EndTurn(now, "couldn't start", false) end,
			left = function(S, ply, name, why, now)
				if S.phase == "prep" then
					G.Next(now)
					return true
				end
				S.last = { name = name, score = 0, reason = why, skipped = true }
			end,
		},
		-- leaving Skater mode ends the turn (a second of grace for hiccups)
		offSkate = { during = { "turn" }, action = function(S, p, now) EndTurn(now, "left Skater mode", true) end },
		tick = {
			turn = function(S, now) if now > S.deadline then EndTurn(now, "time", true) end end,
		},
		handlers = handlers,
	})
	S = G.S

	hook.Add("PlayerDeath", "skategm_" .. T.mode.id, function(ply)
		T.mode:ForPlayer(ply, function()
			if S.active == ply and (S.phase == "turn" or S.phase == "countdown") then EndTurn(CurTime(), "died", S.phase == "turn") end
		end)
	end)
	return T
end
