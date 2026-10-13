-- Hot Potato, server: the game, the bomb and its fuse. Uses only SkateGM.API
-- from the skating add-on.
if not SKATEGM_MODES.Game then include("skategm_modes/sv_game.lua") end

local Skating, Vec = SKATEGM_MODES.Skating, SKATEGM_MODES.Vec
local GM, G

local function Entry(ply) return GM.IndexOf(ply) and GM.Entry(ply) or nil end
local function Alive(ply) local e = Entry(ply) return e ~= nil and e.playing and not e.out end

local function AlivePlayers()
	local list = {}
	for _, p in ipairs(G.players) do if Alive(p) then list[#list + 1] = p end end
	return list
end

-- a fresh bomb, to someone still in (not `avoid` if anyone else is)
local function NewBomb(now, avoid)
	local alive = AlivePlayers()
	if #alive <= 1 then return GM.Results(now, "the game's over") end
	local pick = {}
	for _, p in ipairs(alive) do if p ~= avoid then pick[#pick + 1] = p end end
	if #pick == 0 then pick = alive end
	G.holder = pick[math.random(#pick)]
	G.fuseLen = G.fuse * (1 + POTATO.FUSE_SPREAD * (2 * math.random() - 1))
	G.fuseAt, G.heldSince = now + G.fuseLen, now
	G.passedFrom, G.passedAt, G.armAt = nil, nil, nil
	GM.TellGame(G.holder:Nick() .. " has the bomb!")
	GM.Broadcast(now)
end

local function Boom(now, why)
	local p = G.holder
	G.holder = nil
	if not IsValid(p) then return NewBomb(now) end
	local e = GM.Entry(p)
	e.lives = e.lives - 1
	e.booms = (e.booms or 0) + 1
	G.boomId = (G.boomId or 0) + 1
	G.boom = { id = G.boomId, ent = p:EntIndex(), name = p:Nick() }
	if e.lives <= 0 then
		e.out = true
		GM.TellGame(string.format("BOOM! %s %s - and they're out", p:Nick(), why or "was holding it"))
	else
		GM.TellGame(string.format("BOOM! %s %s (%d %s left)", p:Nick(), why or "was holding it", e.lives, e.lives == 1 and "life" or "lives"))
	end
	if #AlivePlayers() <= 1 then return GM.Results(now, "the game's over") end
	G.armAt, G.avoid = now + POTATO.BETWEEN, p
	GM.Broadcast(now)
end

---------------------------------------------------------------------------
-- passing: the holder's game saw them skate into someone
---------------------------------------------------------------------------
function POTATO.Pass(ply, target, now)
	if G.phase ~= "playing" or ply ~= G.holder then return end
	if now - (G.heldSince or now) < POTATO.HOLD_GRACE then return end
	if not (IsValid(target) and target ~= ply and Alive(target) and Skating(target)) then return end
	if target == G.passedFrom and now - (G.passedAt or 0) < POTATO.NO_TAGBACK then return end
	G.passedFrom, G.passedAt = ply, now
	G.holder, G.heldSince = target, now
	GM.Broadcast(now)
end

local function Host(ply) return GM.Host(ply) end
local handlers = {}

function handlers.startpoint(ply, m, now)
	if not Host(ply) or G.phase ~= "lobby" then return end
	local p = Vec(m.pos)
	if not p then return end
	G.start, G.yaw = p, math.NormalizeAngle(tonumber(m.yaw) or 0)
	GM.Broadcast(now)
end

function handlers.settings(ply, m, now)
	if not Host(ply) then return GM.Tell(ply, "only the host can change the settings") end
	if G.phase ~= "lobby" then return GM.Tell(ply, "settings can be changed between games") end
	G.fuse, G.lives = POTATO.ClampFuse(m.fuse or G.fuse), POTATO.ClampLives(m.lives or G.lives)
	GM.Broadcast(now)
	GM.TellGame(string.format("fuse about %d s, %d %s each", G.fuse, G.lives, G.lives == 1 and "life" or "lives"))
end

function handlers.pass(ply, m, now)
	local target
	for _, p in ipairs(G.players or {}) do if p:EntIndex() == tonumber(m.target) then target = p end end
	POTATO.Pass(ply, target, now)
end

POTATO.ITEM_AREA = 2000
GM = SKATEGM_MODES.Game(POTATO, {
	freeze = false,
	maxPlayers = POTATO.MAX_PLAYERS,
	openText = "a game is already set up: join it",
	noGameText = "no game set up: !potato create starts one",
	resetEntry = function(e) e.playing, e.out, e.lives, e.booms = nil, nil, nil, nil end,
	-- (when the bomb goes off isn't in it: only how much of its fuse is left, for the ticking)
	publicPlayer = function(p, e) return { lives = e.lives, out = e.out, playing = e.playing, booms = e.booms or 0 } end,
	public = function(S, t, now)
		t.start, t.yaw = S.start, S.yaw or 0
		t.fuse, t.lives = S.fuse, S.lives
		if IsValid(S.holder) then
			t.holder = S.holder:EntIndex()
			t.ticking = math.Clamp((S.fuseAt - now) / S.fuseLen, 0, 1)
			t.fuseLen = S.fuseLen
			t.from = IsValid(S.passedFrom) and S.passedFrom:EntIndex() or 0
		end
		t.armIn = S.armAt and math.max(0, S.armAt - now) or nil
		t.boom = S.boom
		t.winner = S.winner
	end,
	create = function(S, ply, m)
		local p = Vec(m.pos)
		if not p then return true end
		S.start, S.yaw = p, math.NormalizeAngle(tonumber(m.yaw) or 0)
		S.fuse, S.lives = POTATO.ClampFuse(m.fuse), POTATO.ClampLives(m.lives)
		S.items = m.items == true
	end,
	-- the host pressed start: everyone in Skater mode plays; anyone still
	-- loading sits this one out
	begin = function(S, now)
		local n = 0
		for _, p in ipairs(S.players) do
			local e = GM.Entry(p)
			e.playing = Skating(p) or nil
			e.lives, e.out, e.booms = S.lives, nil, 0
			if e.playing then n = n + 1 else GM.Tell(p, "not in Skater mode yet: you sit this one out") end
		end
		if n < 2 then return "Hot Potato needs at least two skaters in Skater mode" end
		S.phase, S.deadline, S.boom, S.winner = "countdown", now + POTATO.COUNTDOWN, nil, nil
		GM.Broadcast(now)
	end,
	lobby = function(S) S.winner, S.boom, S.holder, S.armAt, S.passedFrom = nil, nil, nil, nil, nil end,
	results = function(S, now, why)
		S.holder, S.armAt = nil, nil
		local alive = AlivePlayers()
		if #alive == 1 then
			S.winner = { name = alive[1]:Nick() }
			return alive[1]:Nick() .. " survived the bomb and wins!"
		end
		S.winner = nil
		return why or "nobody's left"
	end,
	removed = function(S, ply, now)
		local wasHolder = S.holder == ply
		if S.passedFrom == ply then S.passedFrom = nil end
		if S.phase ~= "playing" then return end
		if #AlivePlayers() <= 1 then GM.Results(now, "everyone else left") return true end
		-- the bomb doesn't leave with them: it jumps to someone else, fuse still burning
		if wasHolder then
			local alive = AlivePlayers()
			S.holder, S.heldSince, S.passedFrom = alive[math.random(#alive)], now, nil
			GM.TellGame("the bomb jumped to " .. S.holder:Nick() .. "!")
		end
	end,
	think = function(S)
		if ITEMS and ITEMS.server and S.start then
			ITEMS.server.Sync(POTATO.mode, S, { on = S.items, centre = Vector(S.start[1], S.start[2], S.start[3]), radius = POTATO.ITEM_AREA })
		end
	end,
	-- a skater still in who drops out of Skater mode is out of the game
	offSkate = {
		during = { "playing" },
		skip = function(S, p) return not Alive(p) end,
		action = function(S, p, now)
			if S.holder == p then
				Boom(now, "ran off with it")
				if S.phase ~= "playing" then return end
			end
			local e = GM.Entry(p)
			e.out, e.lives = true, 0
			GM.Tell(p, "you left Skater mode: you're out of this game")
			if #AlivePlayers() <= 1 then return GM.Results(now, "the game's over") end
		end,
	},
	refresh = { during = { "playing" }, every = 0.5 },
	tick = {
		countdown = function(S, now)
			if now >= S.deadline then
				S.phase, S.deadline = "playing", nil
				S.armAt, S.avoid = now + POTATO.SCATTER, nil
				GM.Broadcast(now)
			end
		end,
		playing = function(S, now)
			if S.armAt and now >= S.armAt then
				local avoid = S.avoid
				S.avoid = nil
				return NewBomb(now, avoid)
			end
			if IsValid(S.holder) and now >= S.fuseAt then return Boom(now) end
		end,
		results = function(S, now) if now >= S.deadline then GM.ToLobby(now) end end,
	},
	handlers = handlers,
})
G = GM.S
POTATO.Think = GM.Tick
