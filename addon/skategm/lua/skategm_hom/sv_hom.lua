if not SKATEGM_MODES.Game then include("skategm_modes/sv_game.lua") end

local Num = SKATEGM_MODES.Num
local G, S

local function EndTurn(now, result, reason)
	local p = S.active
	local e = IsValid(p) and G.Entry(p)
	if e then
		local score = result and math.Clamp(math.floor(tonumber(result.score) or 0), 0, HOM.MAX_SCORE) or 0
		e.turns[#e.turns + 1] = score
		e.best = math.max(e.best, score)
		S.last = { name = p:Nick(), ent = p:EntIndex(), score = score, reason = reason, damage = result and tonumber(result.damage) or 0, air = result and tonumber(result.air) or 0, bonus = result and tonumber(result.bonus) or 0, injuries = result and result.injuries or {} }
		if result then G.TellGame(string.format("%s: %s", p:Nick(), HOM.Commas(score))) end
	end
	G.EndTurn(now)
end

local function SafeInjuries(list)
	local out = {}
	if type(list) ~= "table" then return out end
	for i = 1, math.min(#list, #HOM.PARTS) do
		local inj = list[i]
		if type(inj) == "table" and HOM.PART[inj.part] then
			out[#out + 1] = { part = inj.part, level = math.Clamp(math.floor(tonumber(inj.level) or 0), 1, #HOM.LEVELS) }
		end
	end
	return out
end

local function Active(ply) return S.phase == "turn" and ply == S.active end

G = SKATEGM_MODES.Game(HOM, {
	freeze = false,
	maxPlayers = HOM.MAX_PLAYERS,
	resultsPhase = "final",
	afterResults = "stop",
	openText = "a game is already set up: join it",
	noGameText = "no game to join",
	canJoin = function(S) if S.phase == "final" then return "no game to join" end end,
	entry = function() return { best = 0, turns = {} } end,
	publicPlayer = function(p, e) return { best = e.best, turns = e.turns and #e.turns } end,
	public = function(S, t)
		t.spot, t.yaw = S.spot, S.yaw
		t.turn, t.pain = S.turn, S.pain
		t.live, t.bailing, t.last, t.winner = S.live, S.bailing, S.last, S.winner
	end,
	create = function(S, ply, m)
		local x, y, z = Num(m.x, SKATEGM_MODES.FAR), Num(m.y, SKATEGM_MODES.FAR), Num(m.z, SKATEGM_MODES.FAR)
		if not (x and y and z) then return true end
		S.spot, S.yaw = { x, y, z }, tonumber(m.yaw) or 0
		S.turn, S.rounds = HOM.ClampTurn(m.turn), HOM.ClampRounds(m.rounds)
		S.pain = HOM.PainScale(m.pain)
	end,
	begin = function(S)
		for _, p in ipairs(S.players) do
			local e = G.Entry(p)
			e.best, e.turns = 0, {}
		end
	end,
	lobby = function(S) S.live, S.winner = nil, nil end,
	results = function(S)
		local best, who = -1, nil
		for _, p in ipairs(S.players) do
			local e = G.Entry(p)
			if #e.turns > 0 and e.best > best then best, who = e.best, p end
		end
		S.winner = who and { name = who:Nick(), score = best } or nil
		return who and string.format("%s takes the Hall of Meat with %s!", who:Nick(), HOM.Commas(best)) or "nobody bailed"
	end,
	turns = {
		shared = true,
		lobbyRound = 1,
		time = function(S) return S.turn end,
		skipText = " couldn't get into Skater mode in time: skipped",
		start = function(S) S.live, S.bailing = { score = 0, injuries = {} }, nil end,
		skip = function(S, p, now) EndTurn(now, nil, "skipped") end,
	},
	offSkate = { during = { "turn" }, action = function(S, p, now) EndTurn(now, nil, "left Skater mode") end },
	tick = {
		turn = function(S, now)
			if now > S.deadline then
				if S.bailing then return EndTurn(now, { score = S.live.score, injuries = S.live.injuries }, "bail") end
				return EndTurn(now, nil, "no bail in time")
			end
		end,
	},
	handlers = {
		-- the bail has started in time: no more clock, it runs till it's over
		bailing = function(ply, m, now)
			if not Active(ply) or S.bailing then return end
			S.bailing, S.deadline = true, now + HOM.BAIL_CAP
			G.Broadcast(now)
		end,
		injury = function(ply, m, now)
			if not Active(ply) then return end
			local inj = SafeInjuries({ m })
			if inj[1] then
				S.live.injuries[#S.live.injuries + 1] = inj[1]
				S.live.score = math.Clamp(math.floor(tonumber(m.score) or S.live.score), 0, HOM.MAX_SCORE)
				S.live.at = now
				G.Broadcast(now)
			end
		end,
		result = function(ply, m, now)
			if not Active(ply) then return end
			EndTurn(now, { score = m.score, damage = Num(m.damage), air = Num(m.air), bonus = Num(m.bonus), injuries = SafeInjuries(m.injuries) }, "bail")
		end,
	},
})
S = G.S
HOM.Think = G.Tick
