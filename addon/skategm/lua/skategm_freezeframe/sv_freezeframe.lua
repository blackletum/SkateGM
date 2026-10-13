-- Freeze Frame, server: the game. Uses only SkateGM.API from the skating add-on.
if not SKATEGM_MODES.Game then include("skategm_modes/sv_game.lua") end

local FF = FREEZEFRAME
local G, S
local SHOWING = { show = true, vote = true, out = true }

local function Alive()
	local out = {}
	for _, p in ipairs(S.players or {}) do if G.Entry(p).alive then out[#out + 1] = p end end
	return out
end

local function NextRound(now)
	local alive = Alive()
	if #alive <= 1 then return G.Results(now, alive[1]) end
	S.round = (S.round or 0) + 1
	S.shots, S.photos, S.votes, S.out, S.showIndex = {}, nil, nil, nil, nil
	S.phase, S.deadline = "countdown", now + FF.COUNTDOWN
	G.Broadcast(now)
end

local function Shuffle(t)
	for i = #t, 2, -1 do
		local j = math.random(1, i)
		t[i], t[j] = t[j], t[i]
	end
	return t
end

local function EndShoot(now)
	S.photos = {}
	local missed = {}
	for _, p in ipairs(Alive()) do
		local shot = S.shots[p:EntIndex()]
		if shot then
			S.photos[#S.photos + 1] = { ent = p:EntIndex(), name = p:Nick(), pose = shot.pose, cam = shot.cam, filter = shot.filter }
		else
			missed[#missed + 1] = p
		end
	end
	if #missed > 0 and #S.photos > 0 then
		local names = {}
		for _, p in ipairs(missed) do
			G.Entry(p).alive = nil
			names[#names + 1] = p:Nick()
		end
		G.TellGame(table.concat(names, " and ") .. (#names == 1 and " wasn't" or " weren't") .. " skating when time ran out: out")
	end
	if #S.photos <= 1 then
		S.photos = nil
		return NextRound(now)
	end
	Shuffle(S.photos)
	S.showIndex = 1
	S.phase, S.deadline = "show", now + FF.SHOW
	G.Broadcast(now)
end

local function EndVote(now)
	local candidates = {}
	for _, ph in ipairs(S.photos) do candidates[#candidates + 1] = ph.ent end
	local worst, votes = FF.Worst(S.votes, candidates)
	local name = "?"
	for _, p in ipairs(S.players) do
		if p:EntIndex() == worst then
			G.Entry(p).alive = nil
			name = p:Nick()
		end
	end
	S.out = { ent = worst, name = name, votes = votes }
	S.phase, S.deadline = "out", now + FF.OUT
	G.Broadcast(now)
	G.TellGame(name .. "'s photo got the most votes (" .. votes .. "): out")
end

local handlers = {}

function handlers.photo(ply, m, now)
	if S.phase ~= "shoot" then return end
	local e = G.IndexOf(ply) and G.Entry(ply)
	if not (e and e.alive) or S.shots[ply:EntIndex()] then return end
	local shot = FF.CleanPhoto(m, ply.SkateGMHips)
	if not shot then return G.Tell(ply, "that photo didn't come through: try again") end
	S.shots[ply:EntIndex()] = shot
	G.Broadcast(now)
end

function handlers.vote(ply, m, now)
	if S.phase ~= "vote" then return end
	local e = G.IndexOf(ply) and G.Entry(ply)
	local target = tonumber(m.target)
	if not (e and e.playing and target) or target == ply:EntIndex() then return end
	local ok = false
	for _, ph in ipairs(S.photos) do if ph.ent == target then ok = true end end
	if not ok then return end
	S.votes[ply:EntIndex()] = target
	G.Broadcast(now)
end

G = SKATEGM_MODES.Game(FF, {
	freeze = false,
	minPlayers = 2,
	resetEntry = function(e) e.alive, e.playing = nil, nil end,
	publicPlayer = function(p, e, S)
		return { alive = e.alive or nil, playing = e.playing or nil,
			locked = (S.shots and S.shots[p:EntIndex()] ~= nil) or nil, voted = (S.votes and S.votes[p:EntIndex()] ~= nil) or nil }
	end,
	public = function(S, t)
		t.time, t.round = S.time, S.round
		if SHOWING[S.phase] then
			t.photos = S.photos
			t.showIndex = S.showIndex
		end
		t.out, t.winner = S.out, S.winner
	end,
	create = function(S, ply, m)
		S.time = FF.ClampTime(m.time)
		S.round = 0
	end,
	begin = function(S, now)
		for _, e in pairs(S.entries) do e.alive, e.playing = true, true end
		S.round = 0
		NextRound(now)
	end,
	lobby = function(S) S.round, S.shots, S.photos, S.votes, S.out, S.winner, S.showIndex = 0, nil, nil, nil, nil, nil, nil end,
	results = function(S, now, winner)
		S.winner = winner and { ent = winner:EntIndex(), name = winner:Nick() } or nil
		return winner and (winner:Nick() .. " wins Freeze Frame!") or "nobody's left"
	end,
	removed = function(S, ply, now)
		local ent = ply:EntIndex()
		if S.shots then S.shots[ent] = nil end
		if S.votes then
			S.votes[ent] = nil
			for voter, target in pairs(S.votes) do if target == ent then S.votes[voter] = nil end end
		end
		if S.photos then
			for k = #S.photos, 1, -1 do if S.photos[k].ent == ent then table.remove(S.photos, k) end end
			S.showIndex = S.showIndex and math.min(S.showIndex, math.max(1, #S.photos)) or nil
		end
		if SKATEGM_MODES.InPlay(S) and #Alive() <= 1 then G.Results(now, Alive()[1]) return true end
		if SHOWING[S.phase] and S.phase ~= "out" and #S.photos <= 1 then NextRound(now) return true end
	end,
	tick = {
		countdown = function(S, now)
			if now > S.deadline then
				S.phase, S.deadline = "shoot", now + S.time
				G.Broadcast(now)
			end
		end,
		shoot = function(S, now)
			local all = true
			for _, p in ipairs(Alive()) do if not S.shots[p:EntIndex()] then all = false end end
			if all or now > S.deadline then EndShoot(now) end
		end,
		show = function(S, now)
			if now <= S.deadline then return end
			if S.showIndex < #S.photos then
				S.showIndex = S.showIndex + 1
				S.deadline = now + FF.SHOW
			else
				S.phase, S.deadline, S.votes = "vote", now + FF.VOTE, {}
			end
			G.Broadcast(now)
		end,
		vote = function(S, now)
			local all = true
			for _, p in ipairs(S.players) do
				if G.Entry(p).playing and not S.votes[p:EntIndex()] then all = false end
			end
			if all or now > S.deadline then EndVote(now) end
		end,
		out = function(S, now) if now > S.deadline then NextRound(now) end end,
	},
	handlers = handlers,
})
S = G.S
