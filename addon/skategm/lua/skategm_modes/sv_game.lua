-- A minigame's server: one session table, its players and host, the lobby,
-- results, leaving, freezes and (for turn games) the order of turns. A mode
-- passes its table (T.mode = the registered Mode) and a spec of what's its
-- own; docs/MODES.md lists the spec's fields.
local M = SKATEGM_MODES

M.GAME_RESULTS = 8
M.GAME_PREP = 20
M.GAME_COUNTDOWN = 3
M.GAME_BETWEEN = 3
M.GAME_HOSTING = "%s is hosting %s: join with LB + D-pad left"

local function Set(list)
	if type(list) ~= "table" then return nil end
	local out = {}
	for k, v in pairs(list) do
		if type(k) == "number" then out[v] = true else out[k] = v end
	end
	return out
end

function M.Game(T, spec)
	spec = spec or {}
	local mode = T.mode
	local S = { phase = "idle" }
	local G = { S = S, spec = spec, T = T, mode = mode }
	T.session = S
	mode:UseSessions(S)
	local title = spec.title or mode.title
	local turns = spec.turns
	local resultsPhase = spec.resultsPhase or "results"
	local tick = spec.tick or {}
	local off = spec.offSkate
	local offDuring = off and Set(off.during)
	local refreshDuring = spec.refresh and Set(spec.refresh.during)
	local liveSet = turns and Set(turns.live or { "turn" })
	local firstLive = turns and (turns.live or { "turn" })[1]

	local function Round0() if turns.single then return nil end return turns.lobbyRound or 0 end
	local function Key(ply) return M.Key(ply) end
	G.Key = Key
	function G.Entry(ply) return S.entries and S.entries[Key(ply)] end
	function G.IndexOf(ply) return M.IndexOf(S.players, ply) end
	function G.Ent(ply) return IsValid(ply) and ply:EntIndex() or 0 end
	function G.Name(ply)
		if IsValid(ply) then return ply:Nick() end
		local e = S.entries and S.entries[Key(ply)]
		return e and e.name or "?"
	end
	function G.Host(ply) return S.phase ~= "idle" and S.host == ply end
	function G.InPlay() return M.InPlay(S) end
	function G.Live() return liveSet ~= nil and liveSet[S.phase] == true end

	---------------------------------------------------------------------------
	-- messages: one player, or the game's players and host only
	---------------------------------------------------------------------------
	function G.Tell(ply, text) if IsValid(ply) then mode:Tell(ply, text) end end

	function G.Members()
		local out, seen = {}, {}
		for _, p in ipairs(S.players or {}) do
			if IsValid(p) and not seen[p] then seen[p] = true out[#out + 1] = p end
		end
		if IsValid(S.host) and not seen[S.host] then out[#out + 1] = S.host end
		return out
	end

	local function TellAll(list, text)
		for _, p in ipairs(list) do mode:Tell(p, text) end
	end
	function G.TellGame(text) TellAll(G.Members(), text) end

	---------------------------------------------------------------------------
	-- what every client sees
	---------------------------------------------------------------------------
	function G.Public(now)
		local t = { phase = S.phase }
		if S.phase == "idle" then return t end
		t.host = G.Ent(S.host)
		t.timeLeft = S.deadline and math.max(0, S.deadline - now) or 0
		if turns then
			t.active = G.Ent(S.active)
			t.round, t.rounds = S.round, S.rounds
			if turns.nextUp ~= false then
				local wrap = (S.round or 1) < (S.rounds or 1)
				t.nextUp = M.UpNext(S.order, S.index, wrap)
			end
		end
		if spec.players ~= false then
			t.players = {}
			for _, p in ipairs(S.players or {}) do
				local row = { ent = G.Ent(p), name = G.Name(p) }
				if spec.publicPlayer then
					local extra = spec.publicPlayer(p, S.entries[Key(p)] or {}, S, now)
					for k, v in pairs(extra or {}) do row[k] = v end
				end
				t.players[#t.players + 1] = row
			end
		end
		if spec.public then spec.public(S, t, now) end
		return t
	end

	-- one place decides who's frozen (on every broadcast): in a turn game
	-- everyone but the active player while the game is played; spec.freeze(S, p)
	-- for other games; spec.freeze = false leaves freezing alone
	function G.Freezes()
		if spec.freeze == false then return end
		if type(spec.freeze) ~= "function" then
			if turns then M.FreezeWatchers(S.players, S.active, M.InPlay(S)) end
			return
		end
		for _, p in ipairs(S.players or {}) do
			if IsValid(p) then p:Freeze(spec.freeze(S, p) == true) end
		end
	end

	local function Unfreeze(list)
		if spec.freeze == false then return end
		for _, p in ipairs(list or {}) do if IsValid(p) then p:Freeze(false) end end
	end

	function G.Broadcast(now)
		now = now or CurTime()
		G.Freezes()
		mode:Broadcast(G.Public(now), now)
		S.lastBroadcast = now
	end
	T.Broadcast = G.Broadcast

	---------------------------------------------------------------------------
	-- the end of a game, the lobby, results
	---------------------------------------------------------------------------
	function G.Stop(reason, now)
		local audience = G.Members()
		if spec.stop and S.phase ~= "idle" then spec.stop(S, now) end
		Unfreeze(S.players)
		for k in pairs(S) do S[k] = nil end
		S.phase = "idle"
		G.Broadcast(now)
		if reason then TellAll(audience, reason) end
	end
	T.Stop = G.Stop

	-- back to the lobby, everyone still in; entries of anyone gone dropped
	function G.ToLobby(now)
		now = now or CurTime()
		Unfreeze(S.players)
		S.phase, S.active, S.deadline, S.offSince, S.last = "lobby", nil, nil, nil, nil
		if turns then
			S.order, S.index, S.round = nil, 0, Round0()
		end
		for key, e in pairs(S.entries or {}) do
			if e.left then S.entries[key] = nil elseif spec.resetEntry then spec.resetEntry(e, S) end
		end
		if spec.lobby then spec.lobby(S, now) end
		G.Broadcast(now)
	end
	T.ToLobby = G.ToLobby

	-- spec.results(S, now) sets the mode's winner fields and returns what's said
	function G.Results(now, ...)
		now = now or CurTime()
		local text = spec.results and spec.results(S, now, ...)
		S.phase, S.active, S.deadline = resultsPhase, nil, now + (spec.resultsTime or T.RESULTS or T.FINAL or M.GAME_RESULTS)
		G.Broadcast(now)
		if type(text) == "table" then
			for _, line in ipairs(text) do G.TellGame(line) end
		elseif text then
			G.TellGame(text)
		end
	end

	local function AfterResults(now)
		if spec.afterResults == "stop" then return G.Stop(nil, now) end
		G.ToLobby(now)
	end

	---------------------------------------------------------------------------
	-- turns
	---------------------------------------------------------------------------
	function G.Go(p, now)
		if not (IsValid(p) and G.IndexOf(p)) then return G.Next(now) end
		S.phase, S.active, S.deadline, S.offSince = turns.prep or "prep", p, now + (turns.prepTimeout or T.PREP_TIMEOUT or M.GAME_PREP), nil
		if turns.start then turns.start(S, p, now) end
		G.Broadcast(now)
	end

	function G.Next(now)
		now = now or CurTime()
		if #S.players == 0 then return G.Stop("everyone left: " .. title .. " is over", now) end
		if spec.minPlaying and #S.players < spec.minPlaying then return G.Stop("not enough players left: " .. title .. " is over", now) end
		if turns.pick then
			local p = turns.pick(S, now)
			if not p then return G.Results(now) end
			return G.Go(p, now)
		end
		S.index = (S.index or 0) + 1
		if S.index > #S.order then
			if not S.rounds then
				if turns.done then return turns.done(S, now) end
				return G.Results(now)
			end
			S.index, S.round = 1, (S.round or 0) + 1
			if turns.newRound then turns.newRound(S, now) end
			if S.round > S.rounds then return G.Results(now) end
		end
		G.Go(S.order[S.index], now)
	end
	T.Next = G.Next

	-- the active player's turn is over: a short wait, then the next one
	function G.EndTurn(now, seconds)
		S.phase, S.active, S.deadline = turns.between or "between", nil, now + (seconds or turns.betweenTime or T.BETWEEN or M.GAME_BETWEEN)
		G.Broadcast(now)
	end

	---------------------------------------------------------------------------
	-- the clock
	---------------------------------------------------------------------------
	-- off Skater mode for longer than the grace: true (holder keeps offSince)
	function G.OffSkate(holder, ply, now, seconds)
		if M.Skating(ply) then holder.offSince = nil return false end
		holder.offSince = holder.offSince or now
		if seconds == 0 then return true end
		return now - holder.offSince > (seconds or 1)
	end

	local function Expired(now) return S.deadline ~= nil and now > S.deadline end

	function G.Tick(now)
		if S.phase == "idle" then return end
		if spec.think then spec.think(S, now) end
		local ph = S.phase
		if ph == "idle" then return end
		if ph == "lobby" then
			if tick.lobby then tick.lobby(S, now) end
			return
		end
		if ph == resultsPhase and not tick[ph] then
			if Expired(now) then AfterResults(now) end
			return
		end
		if offDuring and offDuring[ph] then
			if turns and not off.each then
				if G.OffSkate(S, S.active, now, off.seconds) then return off.action(S, S.active, now) end
			else
				for _, p in ipairs({ unpack(S.players) }) do
					local e = S.entries[Key(p)]
					if e and (not off.skip or not off.skip(S, p, e)) and G.OffSkate(e, p, now, off.seconds) then
						off.action(S, p, now)
						if S.phase ~= ph then return end
					end
				end
			end
		end
		if tick[ph] then
			tick[ph](S, now)
		elseif turns and ph == (turns.prep or "prep") then
			if Expired(now) then
				G.TellGame(G.Name(S.active) .. (turns.skipText or " couldn't get into Skater mode in time"))
				turns.skip(S, S.active, now)
			end
		elseif turns and ph == (turns.countdown or "countdown") then
			if Expired(now) then
				S.phase, S.deadline = firstLive, now + (turns.time and turns.time(S) or S.time or 30)
				if turns.go then turns.go(S, now) end
				G.Broadcast(now)
			end
		elseif turns and ph == (turns.between or "between") then
			if Expired(now) then G.Next(now) end
		end
		if refreshDuring and S.phase == ph and refreshDuring[ph] and now - (S.lastBroadcast or 0) >= (spec.refresh.every or 0.5) then G.Broadcast(now) end
	end
	T.Tick = G.Tick
	mode:OnThink(function(now) G.Tick(now) end)

	---------------------------------------------------------------------------
	-- membership
	---------------------------------------------------------------------------
	local function NewEntry(ply)
		local e = spec.entry and spec.entry(ply, S) or {}
		e.name = e.name or ply:Nick()
		return e
	end

	function G.Add(ply, now)
		S.players[#S.players + 1] = ply
		local key = Key(ply)
		local old = S.entries[key]
		if old and old.left then old.left = nil else S.entries[key] = NewEntry(ply) end
		if spec.joined then spec.joined(S, ply, now) end
	end

	-- someone leaving (a command, or disconnecting while the entity is still
	-- valid): out of the order, the host handed on, the game stopped if
	-- nobody's left
	function G.Remove(ply, why, now)
		now = now or CurTime()
		local i = G.IndexOf(ply)
		if not i then return end
		if spec.leaving then
			spec.leaving(S, ply, now)
			i = G.IndexOf(ply)
			if not i then return end
		end
		local audience = G.Members()
		local name = G.Name(ply)
		local wasActive = turns and S.active == ply
		if IsValid(ply) and spec.freeze ~= false then ply:Freeze(false) end
		local k = turns and S.order and S.order ~= S.players and M.IndexOf(S.order, ply)
		table.remove(S.players, i)
		if turns and S.order and not turns.keepOrder then
			if S.order == S.players then k = i elseif k then table.remove(S.order, k) end
			if k and S.index and k <= S.index then S.index = S.index - 1 end
		end
		local key = Key(ply)
		if spec.keepLeft and spec.keepLeft(S, ply) then
			if S.entries[key] then S.entries[key].left = true end
		else
			S.entries[key] = nil
		end
		if #S.players == 0 then return G.Stop("everyone left: " .. title .. " is over", now) end
		if S.host == ply then
			S.host = S.players[1]
			TellAll(G.Members(), G.Name(S.host) .. " is the host now")
		end
		TellAll(audience, name .. " " .. (why or "left the game"))
		if spec.removed and spec.removed(S, ply, now, wasActive) then return end
		if spec.minPlaying and M.InPlay(S) and #S.players < spec.minPlaying then return G.Stop("not enough players left: " .. title .. " is over", now) end
		if wasActive then
			S.active = nil
			if turns.left and turns.left(S, ply, name, why, now) then return end
			S.phase, S.deadline = turns.between or "between", now + 1
		end
		G.Broadcast(now)
	end
	T.Remove = G.Remove
	mode:OnPlayerLeave(function(ply) G.Remove(ply, spec.leaveText or "left the game") end)

	---------------------------------------------------------------------------
	-- commands
	---------------------------------------------------------------------------
	local handlers = {}
	G.handlers = handlers

	-- (spec.needSkate = false: allowed to skate is enough, Skater mode can load later)
	local function CantPlay(ply, m, verb)
		if spec.needSkate ~= false then return mode:CantSkate(ply, m, verb) end
		if M.Allowed(ply) then return false end
		G.Tell(ply, "you're not allowed to skate on this server")
		return true
	end

	function handlers.create(ply, m, now)
		if S.phase ~= "idle" then return G.Tell(ply, spec.openText or "a game is already open") end
		if CantPlay(ply, m, "host") then return end
		for k in pairs(S) do S[k] = nil end
		S.phase, S.host, S.players, S.entries = "lobby", ply, { ply }, {}
		if turns then S.index, S.round = 0, Round0() end
		S.entries[Key(ply)] = NewEntry(ply)
		local err = spec.create and spec.create(S, ply, m, now)
		if err then
			for k in pairs(S) do S[k] = nil end
			S.phase = "idle"
			if type(err) == "string" then G.Tell(ply, err) end
			return
		end
		G.Broadcast(now)
		local text = spec.hosting and spec.hosting(S, ply) or string.format(M.GAME_HOSTING, ply:Nick(), title)
		mode:Tell(nil, text)
	end

	function handlers.join(ply, m, now)
		if S.phase == "idle" then return G.Tell(ply, spec.noGameText or "no game is open") end
		if G.IndexOf(ply) then return end
		local err
		if spec.canJoin then err = spec.canJoin(S, ply, m, now)
		elseif S.phase ~= "lobby" then err = "a game is on: wait for the next one" end
		if err then return G.Tell(ply, err) end
		if CantPlay(ply, m, "play") then return end
		if spec.maxPlayers and #S.players >= spec.maxPlayers then return G.Tell(ply, "the game is full") end
		G.Add(ply, now)
		G.Broadcast(now)
		G.TellGame(ply:Nick() .. " joined" .. (spec.joinedText and spec.joinedText(S, ply) or ""))
	end

	function handlers.leave(ply, m, now) G.Remove(ply, spec.leaveText or "left the game", now) end

	function handlers.begin(ply, m, now)
		if not G.Host(ply) then return G.Tell(ply, "only the host can start") end
		if S.phase ~= "lobby" then return end
		if spec.minPlayers and #S.players < spec.minPlayers then
			return G.Tell(ply, string.format("%s needs at least %d players", title, spec.minPlayers))
		end
		if turns then
			S.order = turns.shared and S.players or { unpack(S.players) }
			S.index, S.round = 0, (not turns.single) and 1 or nil
		end
		local err = spec.begin and spec.begin(S, now)
		if type(err) == "string" then
			if turns then S.order, S.index, S.round = nil, 0, Round0() end
			return G.Tell(ply, err)
		end
		if turns and S.phase == "lobby" then G.Next(now) end
	end

	function handlers.stop(ply, m, now)
		if S.phase == "idle" then return end
		if not (G.Host(ply) or ply:IsAdmin()) then return G.Tell(ply, "only the host or an admin can stop it") end
		if m.close or S.phase == "lobby" then return G.Stop(title .. " was closed by " .. ply:Nick(), now) end
		G.ToLobby(now)
		G.TellGame(ply:Nick() .. " stopped the game: back to the lobby")
	end

	if turns then
		-- the active player is at the start in Skater mode
		function handlers.ready(ply, m, now)
			if S.phase ~= (turns.prep or "prep") or S.active ~= ply then return end
			S.phase, S.deadline = turns.countdown or "countdown", now + (turns.countdownTime or T.COUNTDOWN or M.GAME_COUNTDOWN)
			G.Broadcast(now)
		end
	end

	for cmd, h in pairs(spec.handlers or {}) do handlers[cmd] = h end

	T.Command = mode:Serve(S, handlers, function(why) G.Stop(why) end)
	return G
end
