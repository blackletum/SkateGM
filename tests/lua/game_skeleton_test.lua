dofile("gmock.lua")
SERVER = true
local server = {}
util = setmetatable({ AddNetworkString = function() end, TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }, { __index = util })
net = { Start = function() end, WriteString = function() end, Broadcast = function() end, Receive = function() end, ReadString = function() end, Send = function() end }
local hooks = {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end }
timer = { Simple = function(_, f) f() end }
PrintMessage = function(_, t) server[#server + 1] = t end
HUD_PRINTTALK = 3
function IsValid(x) return x ~= nil and (type(x) ~= "table" or x.valid ~= false) end
local skating = {}
SkateGM = { API = { Allowed = function() return true end, IsSkating = function(p) return skating[p] == true end } }
local function P(id, name)
	local p = { id = id, name = name, valid = true, frozen = false, inbox = {} }
	function p:EntIndex() return self.id end
	function p:UserID() if self.valid == false then error("NULL entity") end return self.id end
	function p:Nick() if self.valid == false then error("NULL entity") end return self.name end
	function p:GetPos() return Vector(self.id * 100, 0, 0) end
	function p:EyeAngles() return { y = 0 } end
	function p:Freeze(b) self.frozen = b end
	function p:IsAdmin() return self.admin == true end
	function p:ChatPrint(t) self.inbox[#self.inbox + 1] = t end
	return p
end
local function check(label, ok) print(string.format("%-78s %s", label, ok and "OK" or "<-- WRONG")) end
local function heard(p, text)
	for _, line in ipairs(p.inbox) do if line:find(text, 1, true) then return true end end
	return false
end
local function said(text)
	for _, line in ipairs(server) do if line:find(text, 1, true) then return true end end
	return false
end

dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_modes/sv_game.lua")
local M = SKATEGM_MODES

FAKE = { mode = M.Register({ id = "fakegame", title = "Fake Game" }) }
FAKE.PREP_TIMEOUT, FAKE.COUNTDOWN, FAKE.BETWEEN, FAKE.RESULTS = 10, 1, 1, 5
local G
G = M.Game(FAKE, {
	minPlayers = 2,
	entry = function() return { total = 0 } end,
	resetEntry = function(e) e.total = 0 end,
	publicPlayer = function(p, e) return { total = e.total } end,
	public = function(S, t) t.last = S.last end,
	create = function(S, ply, m)
		if m.bad then return "put the spot somewhere" end
		S.rounds, S.time = m.rounds or 1, 5
	end,
	results = function(S)
		local best, who = -1, nil
		for _, e in pairs(S.entries) do if e.total > best then best, who = e.total, e.name end end
		S.winner = who
		return (who or "nobody") .. " wins the Fake Game"
	end,
	turns = {
		live = { "turn" },
		skip = function(S, p, now) S.last = "skipped" G.EndTurn(now) end,
	},
	offSkate = { during = { "turn" }, action = function(S, p, now) S.last = "off" G.EndTurn(now) end },
	handlers = {
		score = function(ply, m, now)
			if not G.Live() or FAKE.session.active ~= ply then return end
			local e = G.Entry(ply)
			e.total = e.total + (m.n or 0)
			FAKE.session.last = "scored"
			G.EndTurn(now)
		end,
	},
})
local S = FAKE.session
local now = 100
CurTime = function() return now end
local function cmd(p, m) FAKE.Command(p, m, now) end
local function tick(dt) for _ = 1, math.floor(dt / 0.1 + 0.5) do now = now + 0.1 FAKE.Tick(now) end end
local function play(p, n) cmd(p, { cmd = "ready" }) tick(1.2) cmd(p, { cmd = "score", n = n }) tick(1.2) end

local A, B, C, D, E = P(1, "Ann"), P(2, "Bob"), P(3, "Cat"), P(4, "Dan"), P(5, "Eve")
for _, p in ipairs({ A, B, C, D, E }) do skating[p] = true end

-- creating
cmd(A, { cmd = "create" })
check("create: refused without working Skater mode", S.phase == "idle" and heard(A, "Skater mode working"))
cmd(A, { cmd = "create", canSkate = true, bad = true })
check("create: the mode's own refusal, said to the host, nothing left set up", S.phase == "idle" and S.host == nil and heard(A, "put the spot somewhere"))
cmd(A, { cmd = "create", canSkate = true, rounds = 2 })
check("create: a lobby with the host in it, said server-wide", S.phase == "lobby" and S.host == A and #S.players == 1 and S.entries["1"] and said("Ann is hosting Fake Game"))
cmd(B, { cmd = "create", canSkate = true })
check("... a second create while it's open is refused", S.host == A and heard(B, "already open"))

-- joining and leaving in the lobby
cmd(B, { cmd = "join", canSkate = true })
cmd(C, { cmd = "join", canSkate = true })
cmd(D, { cmd = "join", canSkate = true })
check("join: four in the lobby, members told, outsiders not", #S.players == 4 and heard(A, "Dan joined") and not heard(E, "Dan joined") and not said("Dan joined"))
cmd(D, { cmd = "leave" })
check("leave in the lobby: out, entry gone", #S.players == 3 and S.entries["4"] == nil and heard(A, "Dan left the game") and not heard(E, "Dan left"))
cmd(D, { cmd = "join", canSkate = true })
cmd(B, { cmd = "begin" })
check("begin: only the host", S.phase == "lobby" and heard(B, "only the host can start"))

-- turns: Ann, Bob, Cat, Dan; two rounds
cmd(A, { cmd = "begin" })
check("begin: Ann's turn first, everyone else frozen", S.phase == "prep" and S.active == A and not A.frozen and B.frozen and C.frozen and D.frozen)
check("... the public state says who's on and next", M.Aged(FAKE.mode.lastState, 0).active == 1 and FAKE.mode.lastState.nextUp == 2 and FAKE.mode.lastState.round == 1)
cmd(E, { cmd = "join", canSkate = true })
check("join mid-game: refused", G.IndexOf(E) == nil and heard(E, "wait for the next one"))
play(A, 3)
check("Ann scores, then Bob's turn", S.active == B and S.phase == "prep" and S.entries["1"].total == 3 and A.frozen and not B.frozen)
cmd(B, { cmd = "ready" }) tick(1.2)
cmd(D, { cmd = "leave" })
check("someone after the current turn leaves: unfrozen, out of the order", not D.frozen and #S.order == 3 and S.index == 2 and S.active == B)
cmd(B, { cmd = "score", n = 1 }) tick(1.2)
check("... the turn after Bob's is still Cat's", S.active == C and S.phase == "prep")
cmd(A, { cmd = "leave" })
check("someone before the current turn leaves (the host): index steps back, Cat still on", S.active == C and S.index == 2 and S.order[2] == C)
check("... the host handed on, said once to the game", S.host == B and heard(B, "Bob is the host now") and heard(C, "Bob is the host now") and not heard(E, "host now"))
tick(FAKE.PREP_TIMEOUT + 0.5)
check("prep timeout: Cat skipped, told to the game", S.last == "skipped" and S.phase == "between" and heard(B, "Cat couldn't get into Skater mode in time"))
tick(1.2)
check("round 2: Bob again", S.round == 2 and S.active == B and S.phase == "prep")
cmd(B, { cmd = "ready" }) tick(1.2)
FAKE.mode.leaveHandler(B)
B.valid = false
check("the active player disconnects (still valid when told): the turn ends, Cat hosts", S.phase == "between" and S.active == nil and S.host == C and #S.players == 1)
tick(1.2)
check("... next up is Cat (who was after Bob)", S.active == C and S.phase == "prep")
cmd(C, { cmd = "ready" }) tick(1.2)
skating[C] = false
tick(0.6)
check("off Skater mode: a moment's grace", S.phase == "turn")
tick(0.8)
check("... then the turn's over", S.phase == "between" and S.last == "off")
skating[C] = true
tick(1.2)
check("last turn done: results, said to the game only, nobody frozen", S.phase == "results" and S.winner == "Cat" and heard(C, "Cat wins the Fake Game") and not heard(E, "wins") and not C.frozen)
tick(FAKE.RESULTS + 0.2)
check("results -> lobby: the order and scores cleared, the leavers' entries gone", S.phase == "lobby" and S.order == nil and S.entries["3"].total == 0 and S.entries["1"] == nil)

-- stopping
cmd(D, { cmd = "join", canSkate = true })
cmd(C, { cmd = "begin" })
check("a new game: Cat's turn, Dan frozen", S.phase == "prep" and S.active == C and D.frozen)
cmd(D, { cmd = "stop" })
check("stop: not by a player", S.phase == "prep" and heard(D, "only the host or an admin"))
cmd(C, { cmd = "stop" })
check("stop mid-game: back to the lobby, everyone free", S.phase == "lobby" and not D.frozen and heard(D, "stopped the game"))
cmd(C, { cmd = "begin" })
D.admin = true
cmd(D, { cmd = "stop", close = true })
check("an admin closes it: idle, unfrozen, told to the game only", S.phase == "idle" and not D.frozen and heard(C, "Fake Game was closed by Dan") and not said("closed by"))

-- the entity already gone when it's removed
cmd(C, { cmd = "create", canSkate = true })
cmd(D, { cmd = "join", canSkate = true })
D.valid = false
local ok = pcall(FAKE.Remove, D, "left the game", now)
check("removing a player whose entity is already gone: no error, named from the entry", ok and #S.players == 1 and heard(C, "Dan left the game"))
FAKE.mode.leaveHandler(C)
check("everyone left: it stops, nothing said server-wide", S.phase == "idle" and not said("everyone left"))
D.valid = true

-- two games at once
local H1, H2, P1, P2 = P(11, "Hal"), P(12, "Ivy"), P(13, "Joe"), P(14, "Kim")
for _, p in ipairs({ H1, H2, P1, P2 }) do skating[p] = true end
local clock = 500
local function hc(p, m) clock = clock + 0.01 now = clock FAKE.mode:HandleCommand(p, 10, m, clock) end
hc(H1, { cmd = "create", canSkate = true })
hc(H2, { cmd = "create", canSkate = true })
local k1, k2 = FAKE.mode:SessionOf(H1), FAKE.mode:SessionOf(H2)
hc(P1, { cmd = "join", session = k1, canSkate = true })
hc(P2, { cmd = "join", session = k2, canSkate = true })
check("two games: each has its own players", k1 ~= k2 and #FAKE.mode:SessionData(k1).players == 2 and #FAKE.mode:SessionData(k2).players == 2)
check("... joins told only in their own game", heard(H1, "Joe joined") and not heard(H2, "Joe joined") and heard(H2, "Kim joined") and not heard(H1, "Kim joined"))
hc(H1, { cmd = "begin" })
FAKE.mode:RunThink(clock)
check("one starts: only that one plays, only its watchers frozen", FAKE.mode:SessionData(k1).phase == "prep" and FAKE.mode:SessionData(k2).phase == "lobby" and P1.frozen and not P2.frozen and not H2.frozen)
FAKE.mode:RunThink(clock + FAKE.PREP_TIMEOUT + 1)
check("... its clock runs on its own", FAKE.mode:SessionData(k1).phase == "between" and FAKE.mode:SessionData(k2).phase == "lobby" and not heard(H2, "couldn't get into"))
hc(H2, { cmd = "leave" })
check("the other's host leaves: handed on there only", FAKE.mode:SessionData(k2).host == P2 and FAKE.mode:SessionData(k1).host == H1)
hc(H1, { cmd = "stop", close = true })
check("closing one leaves the other", FAKE.mode:SessionOf(H1) == nil and FAKE.mode:SessionOf(P2) == k2 and not P1.frozen)
