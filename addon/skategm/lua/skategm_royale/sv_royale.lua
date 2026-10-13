-- Run Royale, server: rounds, the replay order, the votes and who's out.
-- Uses only SkateGM.API from the skating add-on.
if not SKATEGM_MODES.Game then include("skategm_modes/sv_game.lua") end

local Skating, Vec = SKATEGM_MODES.Skating, SKATEGM_MODES.Vec
local GM, G

local function Entry(ply) return GM.IndexOf(ply) and GM.Entry(ply) or nil end
local function InMatch(ply) local e = Entry(ply) return e ~= nil and e.inMatch end
local function Alive(ply) local e = Entry(ply) return e ~= nil and e.inMatch and not e.out end

local function AlivePlayers()
	local list = {}
	for _, p in ipairs(G.players or {}) do if Alive(p) then list[#list + 1] = p end end
	return list
end

local function Countdown(now)
	G.round = (G.round or 0) + 1
	G.phase, G.deadline, G.knocked, G.votes, G.order = "countdown", now + ROYALE.COUNTDOWN, nil, nil, nil
	for _, p in ipairs(AlivePlayers()) do GM.Entry(p).score, GM.Entry(p).done = nil, nil end
	GM.Broadcast(now)
end

local function Run(now)
	G.phase, G.deadline = "running", now + G.runTime
	GM.Broadcast(now)
end

local function Replays(now)
	G.order = {}
	for _, p in ipairs(AlivePlayers()) do
		G.order[#G.order + 1] = { ent = p:EntIndex(), name = p:Nick(), score = GM.Entry(p).score }
	end
	G.phase, G.replayIndex, G.replayAt = "replays", 1, now
	G.deadline = now + G.runTime + ROYALE.REPLAY_GAP
	GM.Broadcast(now)
end

local function Voting(now)
	G.phase, G.deadline, G.votes, G.order = "voting", now + ROYALE.VOTE_TIME, {}, nil
	GM.Broadcast(now)
	GM.TellGame("vote for the worst run!")
end

local function Count(now)
	local alive = {}
	for _, p in ipairs(AlivePlayers()) do alive[p:EntIndex()] = p end
	local target = ROYALE.Tally(G.votes or {}, alive)
	local ply = target and alive[target]
	G.votes = nil
	if not ply then return GM.Results(now, "nobody's left") end
	local e = GM.Entry(ply)
	e.out = true
	G.knocked = { ent = ply:EntIndex(), name = ply:Nick() }
	GM.TellGame(ply:Nick() .. " had the worst run and is out!")
	if #AlivePlayers() <= 1 then return GM.Results(now) end
	G.phase, G.deadline = "out", now + ROYALE.OUT_TIME
	GM.Broadcast(now)
end

---------------------------------------------------------------------------
-- votes and scores
---------------------------------------------------------------------------
function ROYALE.Vote(ply, target, now)
	if G.phase ~= "voting" or not InMatch(ply) then return false end
	target = tonumber(target)
	if not target or target == ply:EntIndex() then return false end
	local ok = false
	for _, p in ipairs(AlivePlayers()) do if p:EntIndex() == target then ok = true end end
	if not ok then return false end
	G.votes[ply:EntIndex()] = target
	local all = true
	for _, p in ipairs(G.players) do if InMatch(p) and G.votes[p:EntIndex()] == nil then all = false end end
	if all then G.deadline = math.min(G.deadline, now + 1.5) end
	GM.Broadcast(now)
	return true
end

function ROYALE.Bailed(ply, score, now)
	if not G.bailEnds or G.phase ~= "running" or not Alive(ply) then return false end
	local e = GM.Entry(ply)
	if e.done then return false end
	ROYALE.Score(ply, score, now)
	e.done = true
	local all = true
	for _, p in ipairs(AlivePlayers()) do if not GM.Entry(p).done then all = false end end
	if all then
		GM.TellGame("everyone's bailed: replays")
		G.deadline = now
	end
	GM.Broadcast(now)
	return true
end

function ROYALE.Score(ply, score, now)
	if not Alive(ply) or (G.phase ~= "running" and G.phase ~= "replays") then return false end
	if GM.Entry(ply).done and GM.Entry(ply).score ~= nil then return false end
	score = tonumber(score)
	if not score or score ~= score then return false end
	GM.Entry(ply).score = math.Clamp(math.floor(score), 0, 99999999)
	if G.order then for _, o in ipairs(G.order) do if o.ent == ply:EntIndex() then o.score = GM.Entry(ply).score end end end
	return true
end

local handlers = {}

function handlers.settings(ply, m, now)
	if not GM.Host(ply) then return GM.Tell(ply, "only the host can change the settings") end
	if G.phase ~= "lobby" then return GM.Tell(ply, "settings can be changed between games") end
	G.runTime = ROYALE.ClampRun(m.runTime or G.runTime)
	GM.Broadcast(now)
	GM.TellGame(string.format("%d-second runs", G.runTime))
end

function handlers.vote(ply, m, now) ROYALE.Vote(ply, m.target, now) end
function handlers.score(ply, m, now) ROYALE.Score(ply, m.score, now) end
function handlers.bailed(ply, m, now) ROYALE.Bailed(ply, m.score, now) end

local function Due(S, now) return S.deadline and now >= S.deadline end

GM = SKATEGM_MODES.Game(ROYALE, {
	freeze = false,
	maxPlayers = ROYALE.MAX_PLAYERS,
	openText = "a game is already set up: join it",
	noGameText = "no game set up: !royale create starts one",
	resetEntry = function(e) e.inMatch, e.out, e.score, e.done = nil, nil, nil, nil end,
	-- (who voted for whom isn't in it: only who's voted)
	publicPlayer = function(p, e, S)
		return { inMatch = e.inMatch, out = e.out, done = e.done, voted = S.votes and S.votes[p:EntIndex()] ~= nil or nil, score = e.score }
	end,
	public = function(S, t, now)
		t.start, t.yaw, t.runTime, t.round, t.bailEnds = S.start, S.yaw or 0, S.runTime, S.round or 0, S.bailEnds
		if S.phase == "replays" and S.order then
			local cur = S.order[S.replayIndex]
			t.replay = cur and { ent = cur.ent, name = cur.name, index = S.replayIndex, total = #S.order, at = now - S.replayAt, score = cur.score } or nil
		end
		t.knocked = S.knocked
		t.winner = S.winner
	end,
	create = function(S, ply, m)
		local p = Vec(m.pos)
		if not p then return true end
		S.round = 0
		S.start, S.yaw = p, math.NormalizeAngle(tonumber(m.yaw) or 0)
		S.runTime = ROYALE.ClampRun(m.runTime)
		S.bailEnds = m.bailEnds ~= false
	end,
	begin = function(S, now)
		local n = 0
		for _, p in ipairs(S.players) do
			local e = GM.Entry(p)
			e.inMatch = Skating(p) or nil
			e.out, e.score = nil, nil
			if e.inMatch then n = n + 1 else GM.Tell(p, "not in Skater mode yet: you sit this one out") end
		end
		if n < 2 then return "Run Royale needs at least two skaters in Skater mode" end
		S.round = 0
		Countdown(now)
	end,
	lobby = function(S) S.winner, S.knocked, S.votes, S.order, S.round = nil, nil, nil, nil, 0 end,
	results = function(S, now, why)
		S.votes, S.order = nil, nil
		local alive = AlivePlayers()
		S.winner = #alive == 1 and { name = alive[1]:Nick(), ent = alive[1]:EntIndex() } or nil
		return S.winner and (S.winner.name .. " wins Run Royale!") or (why or "nobody's left")
	end,
	removed = function(S, ply, now)
		local ent = ply.EntIndex and ply:EntIndex()
		if S.votes and ent then
			S.votes[ent] = nil
			for voter, target in pairs(S.votes) do if target == ent then S.votes[voter] = nil end end
		end
		if SKATEGM_MODES.InPlay(S) and #AlivePlayers() <= 1 then GM.Results(now, "everyone else left") return true end
	end,
	refresh = { during = { "replays" }, every = 0.5 },
	tick = {
		countdown = function(S, now) if Due(S, now) then Run(now) end end,
		running = function(S, now) if Due(S, now) then Replays(now) end end,
		replays = function(S, now)
			if not Due(S, now) then return end
			if S.replayIndex < #S.order then
				S.replayIndex, S.replayAt = S.replayIndex + 1, now
				S.deadline = now + S.runTime + ROYALE.REPLAY_GAP
				return GM.Broadcast(now)
			end
			Voting(now)
		end,
		voting = function(S, now) if Due(S, now) then Count(now) end end,
		out = function(S, now) if Due(S, now) then Countdown(now) end end,
		results = function(S, now) if Due(S, now) then GM.ToLobby(now) end end,
	},
	handlers = handlers,
})
G = GM.S
ROYALE.Think = GM.Tick
