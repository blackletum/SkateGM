-- Copycat, server: the game. Uses only SkateGM.API from the skating add-on.
-- The lines are judged here from where each skater's hips were (SkateGMHips).
if not SKATEGM_MODES.Game then include("skategm_modes/sv_game.lua") end

local CC = COPYCAT
local G, S

local function PlayerOf(ent)
	for _, p in ipairs(S.players or {}) do if p:EntIndex() == ent then return p end end
end

local function Rounded(path)
	local out = {}
	for i, p in ipairs(path or {}) do out[i] = { math.floor(p[1] + 0.5), math.floor(p[2] + 0.5), math.floor(p[3] + 0.5) } end
	return out
end

local SHOWING = { replay = true, score = true }

local function Sample(ents, now)
	if now < (S.nextSample or 0) or now < (S.sampleFrom or 0) then return end
	S.nextSample = now + CC.SAMPLE
	for _, ent in ipairs(ents) do
		local p = PlayerOf(ent)
		local at = IsValid(p) and p.SkateGMHips
		if at then
			local path = S.paths[ent] or {}
			path[#path + 1] = { at.x, at.y, at.z }
			S.paths[ent] = path
		end
	end
end

local function Judge()
	S.scores = {}
	for _, ent in ipairs(S.copiers) do S.scores[ent] = CC.Match(S.paths[S.leader], S.paths[ent], S.judging) end
end

local NextLeader

local function NextReplay(now)
	S.replayIndex = (S.replayIndex or 0) + 1
	while S.copiers[S.replayIndex] and not PlayerOf(S.copiers[S.replayIndex]) do S.replayIndex = S.replayIndex + 1 end
	if S.replayIndex > #S.copiers then return NextLeader(now) end
	S.phase, S.deadline, S.last = "replay", now + (S.lineTime or S.runTime) + CC.REPLAY_GAP, nil
	G.Broadcast(now)
end

local function Score(now)
	local ent = S.copiers[S.replayIndex]
	local p = PlayerOf(ent)
	local pct = S.scores[ent] or 0
	local e = p and G.Entry(p)
	if e then e.points = e.points + pct end
	S.last = { ent = ent, name = p and p:Nick() or "?", points = pct }
	S.phase, S.deadline = "score", now + CC.SCORE
	G.Broadcast(now)
end

function NextLeader(now)
	S.lead = (S.lead or 0) + 1
	while S.order[S.lead] and not PlayerOf(S.order[S.lead]) do S.lead = S.lead + 1 end
	if S.lead > #S.order then return G.Results(now) end
	S.leader = S.order[S.lead]
	S.copiers = {}
	for _, p in ipairs(S.players) do
		if G.Entry(p).playing and p:EntIndex() ~= S.leader then S.copiers[#S.copiers + 1] = p:EntIndex() end
	end
	S.paths, S.scores, S.replayIndex, S.last = {}, {}, nil, nil
	S.phase, S.deadline = "leadcount", now + CC.COUNTDOWN
	G.Broadcast(now)
	local lp = PlayerOf(S.leader)
	G.TellGame((lp and lp:Nick() or "?") .. " sets the line: watch closely")
end

G = SKATEGM_MODES.Game(CC, {
	freeze = false,
	minPlayers = 2,
	entry = function() return { points = 0 } end,
	resetEntry = function(e) e.points, e.playing = 0, nil end,
	publicPlayer = function(p, e) return { points = e.points or 0, playing = e.playing or nil } end,
	public = function(S, t)
		t.start, t.yaw, t.runTime, t.judging = { S.start.x, S.start.y, S.start.z }, S.yaw, S.runTime, S.judging
		t.leader = S.leader
		t.round = S.lead and { index = S.lead, total = #S.order } or nil
		t.copiers = S.copiers
		if SHOWING[S.phase] and S.copiers and S.replayIndex then
			local ent = S.copiers[S.replayIndex]
			t.replay = { index = S.replayIndex, total = #S.copiers, ent = ent }
			t.paths = { lead = Rounded(S.paths[S.leader]), copy = Rounded(S.paths[ent]) }
		end
		t.last, t.winners = S.last, S.winners
	end,
	create = function(S, ply, m)
		S.start, S.yaw = SKATEGM_MODES.HostStart(ply, m)
		S.runTime, S.judging = CC.ClampRun(m.runTime), CC.Judging(m.judging)
	end,
	begin = function(S, now)
		S.order = {}
		for _, p in ipairs(S.players) do
			local e = G.Entry(p)
			e.playing, e.points = true, 0
			S.order[#S.order + 1] = p:EntIndex()
		end
		S.lead = 0
		NextLeader(now)
	end,
	lobby = function(S)
		S.order, S.lead, S.leader, S.copiers, S.replayIndex, S.paths, S.scores, S.winners = nil, nil, nil, nil, nil, nil, nil, nil
	end,
	results = function(S)
		local best, names = -1, {}
		for _, p in ipairs(S.players) do
			local e = G.Entry(p)
			if e.playing then
				if e.points > best then best, names = e.points, { p:Nick() } elseif e.points == best then names[#names + 1] = p:Nick() end
			end
		end
		S.winners = { names = names, points = math.max(0, best) }
		S.leader, S.copiers, S.replayIndex = nil, nil, nil
		return #names > 0 and (table.concat(names, " and ") .. " win" .. (#names == 1 and "s" or "") .. " Copycat with " .. best .. " points") or "nobody scored"
	end,
	removed = function(S, ply, now)
		local ent = ply:EntIndex()
		local inGame = SKATEGM_MODES.InPlay(S)
		if inGame and #S.players < 2 then
			G.Stop("not enough players left: Copycat is over", now)
			return true
		end
		if S.copiers then
			local k = SKATEGM_MODES.IndexOf(S.copiers, ent)
			if k and not SHOWING[S.phase] then table.remove(S.copiers, k) end
		end
		if inGame and S.leader == ent then NextLeader(now) return true end
		if SHOWING[S.phase] and S.copiers[S.replayIndex] == ent then NextReplay(now) return true end
	end,
	tick = {
		leadcount = function(S, now)
			if now > S.deadline then
				S.phase, S.deadline, S.nextSample, S.sampleFrom = "lead", now + S.runTime, nil, now + CC.SETTLE
				S.leadStart, S.lineTime = now, S.runTime
				G.Broadcast(now)
			end
		end,
		lead = function(S, now)
			Sample({ S.leader }, now)
			if now > S.deadline then CC.EndLead(now) end
		end,
		copycount = function(S, now)
			if now > S.deadline then
				S.phase, S.deadline, S.nextSample, S.sampleFrom = "copy", now + S.lineTime, nil, now + CC.SETTLE
				G.Broadcast(now)
			end
		end,
		copy = function(S, now)
			Sample(S.copiers, now)
			if now > S.deadline then
				Judge()
				NextReplay(now)
			end
		end,
		replay = function(S, now) if now > S.deadline then Score(now) end end,
		score = function(S, now) if now > S.deadline then NextReplay(now) end end,
	},
	handlers = {
		-- the setter bailed: their line ends there
		bailed = function(ply, m, now)
			if S.phase ~= "lead" or not IsValid(ply) or ply:EntIndex() ~= S.leader then return end
			CC.EndLead(now, true)
		end,
	},
})
S = G.S

-- the setter's line is over (its time, or a bail): the copies get as long
-- as the line took
function CC.EndLead(now, bailed)
	S.lineTime = math.max(CC.MIN_LINE, math.min(S.runTime, now - (S.leadStart or now)))
	S.phase, S.deadline = "copycount", now + CC.COUNTDOWN
	G.Broadcast(now)
	local lp = PlayerOf(S.leader)
	G.TellGame((bailed and ((lp and lp:Nick() or "?") .. " bailed: that's the line. ") or "") .. "your turn: copy that line")
end
