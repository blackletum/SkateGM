-- Imposter, server: the game. Uses only SkateGM.API from the skating add-on.
if not SKATEGM_MODES.Game then include("skategm_modes/sv_game.lua") end

util.AddNetworkString(IMPOSTER.NET_ROLE)
local G, S

local function SendRole(ply)
	if not IsValid(ply) or not S.imposter then return end
	local imposter = ply == S.imposter
	net.Start(IMPOSTER.NET_ROLE)
	net.WriteBool(imposter)
	net.WriteUInt(imposter and 0 or S.target, 32)
	net.Send(ply)
end
IMPOSTER.SendRole = SendRole

local function EndTurn(now, score, how)
	local p = S.active
	local e = IsValid(p) and G.Entry(p)
	if e then e.done, e.score, e.how = true, math.Clamp(math.floor(score or 0), 0, IMPOSTER.MAX_SCORE), how end
	S.last = { name = IsValid(p) and p:Nick() or "?", ent = IsValid(p) and p:EntIndex() or nil }
	G.EndTurn(now)
end

local function AllVoted()
	for _, p in ipairs(S.players) do if S.votes[p:EntIndex()] == nil then return false end end
	return true
end

G = SKATEGM_MODES.Game(IMPOSTER, {
	minPlayers = IMPOSTER.MIN_PLAYERS,
	minPlaying = 2,
	keepLeft = function(S) return SKATEGM_MODES.InPlay(S) end,
	resetEntry = function(e) e.done, e.score, e.how = nil, nil, nil end,
	publicPlayer = function(p, e, S) return { done = e.done or nil, voted = S.votes and S.votes[p:EntIndex()] ~= nil or nil } end,
	public = function(S, t)
		t.spot = { S.spot.x, S.spot.y, S.spot.z }
		t.yaw, t.turn, t.difficulty, t.imposterFirst = S.yaw, S.turn, S.difficulty, S.imposterFirst
		t.index, t.turns = S.index, S.order and #S.order or 0
		t.last = S.last
		if S.phase == "results" then t.result = S.result end
	end,
	create = function(S, ply, m)
		S.spot, S.yaw = SKATEGM_MODES.HostStart(ply, m)
		S.turn = IMPOSTER.ClampTurn(m.turn)
		S.difficulty = IMPOSTER.Difficulty(m.difficulty)[1]
		S.imposterFirst = m.imposterFirst == true
	end,
	begin = function(S)
		S.imposter = S.players[math.random(1, #S.players)]
		S.imposterKey, S.imposterName = G.Key(S.imposter), S.imposter:Nick()
		S.target = IMPOSTER.PickTarget(S.difficulty)
		S.order = IMPOSTER.Order(S.players, S.imposter, S.imposterFirst)
		for _, e in pairs(S.entries) do e.done, e.score, e.how = nil, nil, nil end
		for _, p in ipairs(S.players) do SendRole(p) end
	end,
	lobby = function(S) S.votes, S.result, S.imposter, S.target = nil, nil, nil, nil end,
	results = function(S, now, why)
		local out, count = IMPOSTER.Tally(S.votes or {})
		local imposterEnt = G.Ent(S.imposter)
		local r = { imposter = imposterEnt, imposterName = S.imposterName, target = S.target, out = out, why = why, lines = {}, votes = {} }
		r.crewWin = out ~= nil and out == imposterEnt
		for key, e in pairs(S.entries) do
			if e.done then r.lines[#r.lines + 1] = { name = e.name, score = e.score, how = e.how, imposter = key == S.imposterKey or nil } end
		end
		table.sort(r.lines, function(a, b) return math.abs(a.score - S.target) < math.abs(b.score - S.target) end)
		for ent, n in pairs(count) do r.votes[#r.votes + 1] = { ent = ent, n = n } end
		table.sort(r.votes, function(a, b) return a.n > b.n end)
		for _, l in ipairs(r.lines) do if not l.imposter then r.closest = l.name break end end
		S.result = r
		local said = string.format("%s was the impostor: %s", S.imposterName or "?", r.crewWin and "caught!" or "they got away with it")
		return why and { why, said } or said
	end,
	removed = function(S, ply, now)
		if S.votes then
			S.votes[ply:EntIndex()] = nil
			for voter, target in pairs(S.votes) do if target == ply:EntIndex() then S.votes[voter] = nil end end
		end
		if SKATEGM_MODES.InPlay(S) and ply == S.imposter then
			G.Results(now, "the impostor left")
			return true
		end
	end,
	turns = {
		single = true,
		live = { "turn", "finish" },
		time = function(S) return S.turn end,
		skipText = " couldn't get into Skater mode in time: skipped",
		skip = function(S, p, now) EndTurn(now, 0, "skipped") end,
		left = function(S, ply, name) S.last = { name = name } end,
		done = function(S, now)
			S.phase, S.active, S.deadline, S.votes = "vote", nil, now + IMPOSTER.VOTE_TIME, {}
			G.Broadcast(now)
			G.TellGame("who didn't know the score? vote them out!")
		end,
	},
	offSkate = { during = { "turn", "finish" }, action = function(S, p, now) EndTurn(now, 0, "left Skater mode") end },
	tick = {
		turn = function(S, now)
			if now > S.deadline then
				S.phase, S.deadline = "finish", now + IMPOSTER.FINISH
				G.Broadcast(now)
			end
		end,
		finish = function(S, now) if now > S.deadline then EndTurn(now, 0, "out of time") end end,
		vote = function(S, now) if now > S.deadline or AllVoted() then G.Results(now) end end,
	},
	handlers = {
		landed = function(ply, m, now)
			if S.active ~= ply or not G.Live() then return end
			local how = m.how == "bail" and "bailed" or (m.how == "none" and "no line" or "landed")
			EndTurn(now, how == "landed" and tonumber(m.score) or 0, how)
		end,
		vote = function(ply, m, now)
			if S.phase ~= "vote" or not G.IndexOf(ply) then return end
			local target = tonumber(m.target)
			if not target or target == ply:EntIndex() then return end
			local ok = false
			for _, p in ipairs(S.players) do if p:EntIndex() == target then ok = true end end
			if not ok then return end
			S.votes[ply:EntIndex()] = target
			G.Broadcast(now)
		end,
		role = function(ply) if SKATEGM_MODES.InPlay(S) and G.IndexOf(ply) then SendRole(ply) end end,
	},
})
S = G.S
IMPOSTER.Results = G.Results
