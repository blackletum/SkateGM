-- Race, server: the race itself. Uses only SkateGM.API from the skating add-on.
if not SKATEGM_MODES.Game then include("skategm_modes/sv_game.lua") end

local Skating, Vec = SKATEGM_MODES.Skating, SKATEGM_MODES.Vec
local G, R

-- still racing: in this race, not finished, not out of it
local function Racing(e) return e and e.racing and not e.time and not e.dnf end

local function AnyRacing()
	for _, p in ipairs(R.players) do if Racing(G.Entry(p)) then return true end end
	return false
end

local function Finished(ply, now)
	local e = G.Entry(ply)
	if not Racing(e) or R.phase ~= "racing" then return end
	local t = now - R.startedAt
	if t < 1 then return end -- nobody finishes in under a second
	e.time, e.place = t, R.nextPlace
	R.nextPlace = R.nextPlace + 1
	G.TellGame(string.format("%s finished %s in %s", ply:Nick(), e.place == 1 and "FIRST" or ("#" .. e.place), RACE.Time(t)))
	-- everyone still racing done? (someone out of the race doesn't count)
	if AnyRacing() then return G.Broadcast(now) end
	G.Results(now, "everyone's in")
end

local function Host(ply) return G.Host(ply) and R.phase == "lobby" end
local handlers = {}

function handlers.start(ply, m, now)
	if not Host(ply) then return end
	local p = Vec(m.pos)
	if not p then return end
	R.start, R.yaw = p, math.NormalizeAngle(tonumber(m.yaw) or 0)
	G.Tell(ply, "start placed")
	G.Broadcast(now)
end

function handlers.finish(ply, m, now)
	if not Host(ply) then return end
	local p = Vec(m.pos)
	if not p then return end
	R.finish = p
	G.Tell(ply, "finish placed")
	G.Broadcast(now)
end

function handlers.settings(ply, m, now)
	if not Host(ply) then return end
	R.radius, R.limit = RACE.ClampRadius(m.radius or R.radius), RACE.ClampLimit(m.limit or R.limit)
	G.Broadcast(now)
end

function handlers.finished(ply, m, now) Finished(ply, now) end

G = SKATEGM_MODES.Game(RACE, {
	freeze = false,
	needSkate = false,
	maxPlayers = RACE.MAX_PLAYERS,
	openText = "a race is already set up: join it",
	noGameText = "no race set up",
	canJoin = function(S) if S.phase ~= "lobby" then return "the race has started: wait for the next one" end end,
	leaveText = "left the race",
	hosting = function(S, ply) return ply:Nick() .. " is hosting a race: join with LB + D-pad left" end,
	keepLeft = function(S, ply) local e = G.Entry(ply) return e and e.time ~= nil end,
	resetEntry = function(e) e.racing, e.time, e.place, e.dnf = nil, nil, nil, nil end,
	publicPlayer = function(p, e) return { racing = e.racing, time = e.time, place = e.place, out = e.dnf } end,
	public = function(S, t, now)
		t.start = S.start and { S.start.x, S.start.y, S.start.z } or nil
		t.yaw = S.yaw or 0
		t.finish = S.finish and { S.finish.x, S.finish.y, S.finish.z } or nil
		t.radius, t.limit = S.radius, S.limit
		t.elapsed = S.startedAt and math.max(0, now - S.startedAt) or 0
		t.count = #S.players
		t.gone = {}
		for _, e in pairs(S.entries) do
			if e.left and e.time then t.gone[#t.gone + 1] = { name = e.name, time = e.time, place = e.place } end
		end
	end,
	create = function(S, ply, m)
		S.radius, S.limit = RACE.ClampRadius(m.radius), RACE.ClampLimit(m.limit)
		S.start, S.finish = Vec(m.start), Vec(m.finish)
		S.yaw = math.NormalizeAngle(tonumber(m.yaw) or 0)
	end,
	-- the host pressed start: everyone in Skater mode races, straight to the
	-- countdown on the start; anyone still loading sits this one out (and is
	-- ready for the next)
	begin = function(S, now)
		if not (S.start and S.finish) then return "place the start and the finish first" end
		if S.start:Distance(S.finish) < S.radius * 2 then return "the finish is too close to the start" end
		local n = 0
		for _, p in ipairs(S.players) do
			local e = G.Entry(p)
			e.racing = Skating(p) or nil
			if e.racing then n = n + 1 else G.Tell(p, "not in Skater mode yet: you sit this race out") end
		end
		if n == 0 then return "nobody's in Skater mode yet" end
		S.phase, S.deadline = "countdown", now + RACE.COUNTDOWN
		G.Broadcast(now)
	end,
	lobby = function(S) S.startedAt = nil end,
	results = function(S, now, why)
		local finished, racers = 0, 0
		for _, e in pairs(S.entries) do
			if e.time then finished = finished + 1 end
			if e.racing then racers = racers + 1 end
		end
		return (why or "race over") .. string.format(" - %d of %d finished", finished, racers)
	end,
	-- nobody left racing: straight to the results
	removed = function(S, ply, now)
		if S.phase == "racing" and not AnyRacing() then
			G.Results(now, "everyone's in")
			return true
		end
	end,
	-- a racer who drops out of Skater mode mid-race is out of it
	offSkate = {
		during = { "racing" }, seconds = 0,
		skip = function(S, p, e) return not Racing(e) end,
		action = function(S, p)
			G.Entry(p).dnf = true
			G.Tell(p, "you left Skater mode: you're out of this race")
		end,
	},
	refresh = { during = { "racing" }, every = 1 },
	tick = {
		countdown = function(S, now)
			if now >= S.deadline then
				S.phase, S.startedAt, S.deadline = "racing", now, now + S.limit
				S.nextPlace = 1
				G.Broadcast(now)
			end
		end,
		racing = function(S, now)
			if now >= S.deadline then return G.Results(now, "time's up") end
			if not AnyRacing() then return G.Results(now, "everyone's in") end
		end,
		results = function(S, now) if now >= S.deadline then G.ToLobby(now) end end,
	},
	handlers = handlers,
})
R = G.S
RACE.Think = G.Tick
