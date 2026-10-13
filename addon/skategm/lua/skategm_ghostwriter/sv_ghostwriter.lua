-- Ghost Writer, server: the game. Uses only SkateGM.API from the skating add-on.
if not SKATEGM_MODES.Game then include("skategm_modes/sv_game.lua") end

local GW = GHOSTWRITER
local G, S

local function Replay(now)
	S.phase, S.guesses, S.reveal = "replay", nil, nil
	S.deadline = now + S.runTime + GW.REPLAY_GAP
	G.Broadcast(now)
end

local function Present(ent)
	for _, p in ipairs(S.players) do if p:EntIndex() == ent then return true end end
	return false
end

local NextReveal

local function NextReplay(now)
	S.replayIndex = (S.replayIndex or 0) + 1
	while S.order[S.replayIndex] and not Present(S.order[S.replayIndex]) do S.replayIndex = S.replayIndex + 1 end
	if S.replayIndex > #S.order then
		S.replayIndex = 0
		return NextReveal(now)
	end
	Replay(now)
end

local function Guessers(index)
	local out = {}
	local runner = S.order[index or S.replayIndex]
	for _, p in ipairs(S.players) do
		local e = G.Entry(p)
		if e.inRun and p:EntIndex() ~= runner then out[#out + 1] = p end
	end
	return out
end

-- the guesses for a run are kept, unseen, until every run has been guessed
local function Keep(now)
	S.kept = S.kept or {}
	S.kept[S.replayIndex] = S.guesses or {}
	S.guesses = nil
	NextReplay(now)
end

-- after the last run: each one in turn, who it was and who got it
local function Reveal(now)
	local runnerEnt = S.order[S.replayIndex]
	local runner
	for _, p in ipairs(S.players) do if p:EntIndex() == runnerEnt then runner = p end end
	local guesses = S.kept and S.kept[S.replayIndex] or {}
	local right, fooled, picks = {}, 0, {}
	for _, p in ipairs(Guessers()) do
		local g = guesses[p:EntIndex()]
		picks[#picks + 1] = { by = p:EntIndex(), target = g or 0 }
		if g == runnerEnt then
			G.Entry(p).points = G.Entry(p).points + 1
			right[#right + 1] = p:Nick()
		else
			fooled = fooled + 1
		end
	end
	if runner then G.Entry(runner).points = G.Entry(runner).points + fooled end
	S.reveal = { name = runner and runner:Nick() or "?", ent = runnerEnt, right = right, fooled = fooled, picks = picks, index = S.replayIndex, total = #S.order }
	S.phase, S.deadline = "reveal", now + GW.REVEAL
	G.Broadcast(now)
end

function NextReveal(now)
	S.replayIndex = (S.replayIndex or 0) + 1
	while S.order[S.replayIndex] and not Present(S.order[S.replayIndex]) do S.replayIndex = S.replayIndex + 1 end
	if S.replayIndex > #S.order then return G.Results(now) end
	Reveal(now)
end

local handlers = {}

function handlers.guess(ply, m, now)
	if S.phase ~= "guess" or not G.IndexOf(ply) then return end
	local target = tonumber(m.target)
	if not target or ply:EntIndex() == S.order[S.replayIndex] or target == ply:EntIndex() then return end
	local ok = false
	for _, p in ipairs(S.players) do if p:EntIndex() == target and G.Entry(p).inRun then ok = true end end
	if not ok then return end
	S.guesses[ply:EntIndex()] = target
	G.Broadcast(now)
end

local SHOWN = { lobby = true, reveal = true, results = true }

G = SKATEGM_MODES.Game(GW, {
	freeze = false,
	minPlayers = 3,
	entry = function() return { points = 0 } end,
	resetEntry = function(e) e.points, e.inRun = 0, nil end,
	publicPlayer = function(p, e, S)
		return { points = SHOWN[S.phase] and (e.points or 0) or nil, inRun = e.inRun or nil,
			guessed = S.guesses and S.guesses[p:EntIndex()] ~= nil or nil }
	end,
	public = function(S, t)
		t.start, t.yaw, t.runTime = { S.start.x, S.start.y, S.start.z }, S.yaw, S.runTime
		if S.order and S.replayIndex and (S.phase == "replay" or S.phase == "guess" or S.phase == "reveal") then
			t.replay = { index = S.replayIndex, total = #S.order, ent = S.order[S.replayIndex] }
		end
		t.reveal, t.winners = S.reveal, S.winners
	end,
	create = function(S, ply, m)
		S.start, S.yaw = SKATEGM_MODES.HostStart(ply, m)
		S.runTime = GW.ClampRun(m.runTime)
	end,
	begin = function(S, now)
		S.order = {}
		for _, p in ipairs(S.players) do
			local e = G.Entry(p)
			e.inRun, e.points = true, 0
			S.order[#S.order + 1] = p:EntIndex()
		end
		for i = #S.order, 2, -1 do
			local j = math.random(1, i)
			S.order[i], S.order[j] = S.order[j], S.order[i]
		end
		S.replayIndex = 0
		S.phase, S.deadline = "countdown", now + GW.COUNTDOWN
		G.Broadcast(now)
	end,
	lobby = function(S) S.order, S.replayIndex, S.guesses, S.reveal, S.winners, S.kept = nil, nil, nil, nil, nil, nil end,
	results = function(S)
		local best, names = -1, {}
		for _, p in ipairs(S.players) do
			local e = G.Entry(p)
			if e.inRun then
				if e.points > best then best, names = e.points, { p:Nick() } elseif e.points == best then names[#names + 1] = p:Nick() end
			end
		end
		S.winners = { names = names, points = math.max(0, best) }
		return #names > 0 and (table.concat(names, " and ") .. " win" .. (#names == 1 and "s" or "") .. " Ghost Writer with " .. best .. " points") or "nobody scored"
	end,
	removed = function(S, ply, now)
		local ent = ply:EntIndex()
		for _, g in pairs(S.kept or {}) do g[ent] = nil end
		if S.guesses then
			S.guesses[ent] = nil
			for voter, target in pairs(S.guesses) do if target == ent then S.guesses[voter] = nil end end
		end
		if SKATEGM_MODES.InPlay(S) and #S.players < 2 then
			G.Stop("not enough players left: Ghost Writer is over", now)
			return true
		end
		if S.order and S.order[S.replayIndex] == ent and (S.phase == "replay" or S.phase == "guess") then
			S.guesses = nil
			NextReplay(now)
			return true
		end
		if S.order and S.order[S.replayIndex] == ent and S.phase == "reveal" then NextReveal(now) return true end
	end,
	tick = {
		countdown = function(S, now)
			if now > S.deadline then
				S.phase, S.deadline = "running", now + S.runTime
				G.Broadcast(now)
			end
		end,
		running = function(S, now) if now > S.deadline then NextReplay(now) end end,
		replay = function(S, now)
			if now > S.deadline then
				S.phase, S.deadline, S.guesses = "guess", now + GW.GUESS_TIME, {}
				G.Broadcast(now)
			end
		end,
		guess = function(S, now)
			local all = true
			for _, p in ipairs(Guessers()) do if S.guesses[p:EntIndex()] == nil then all = false end end
			if now > S.deadline or all then Keep(now) end
		end,
		reveal = function(S, now) if now > S.deadline then NextReveal(now) end end,
	},
	handlers = handlers,
})
S = G.S
