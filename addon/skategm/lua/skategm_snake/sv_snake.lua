util.AddNetworkString(SNAKE.NET_TRAIL)
if not SKATEGM_MODES.Game then include("skategm_modes/sv_game.lua") end

local Skating, Num = SKATEGM_MODES.Skating, SKATEGM_MODES.Num
local GM, G

local function Entry(ply) return GM.IndexOf(ply) and GM.Entry(ply) or nil end
local function Alive(ply) local e = Entry(ply) return e ~= nil and e.playing and not e.out end

local function Ground(x, y, z) return SKATEGM_MODES.Ground(x, y, z) end

local function SendTrail(ply, pts, clear)
	net.Start(SNAKE.NET_TRAIL)
	net.WriteString(util.TableToJSON({ ent = ply:EntIndex(), p = pts, len = GM.Entry(ply) and GM.Entry(ply).length or 0, clear = clear }))
	net.Broadcast()
end

local function NewPellet(id)
	local a = G.area
	local ang, r = math.random() * math.pi * 2, math.sqrt(math.random()) * a[4] * 0.9
	local x, y = a[1] + math.cos(ang) * r, a[2] + math.sin(ang) * r
	return { id = id, x = x, y = y, z = Ground(x, y, a[3]) }
end

local function AliveList()
	local list = {}
	for _, p in ipairs(G.players) do if Alive(p) then list[#list + 1] = p end end
	return list
end

local function Out(ply, now, why)
	local e = Entry(ply)
	if not e or not e.playing or e.out then return end
	e.out = true
	e.place = #AliveList() + 1
	SendTrail(ply, {}, true)
	e.trail = {}
	GM.TellGame(ply:Nick() .. " is out" .. (why and (": " .. why) or ""))
	local alive = AliveList()
	if (G.started > 1 and #alive <= 1) or #alive == 0 then return GM.Results(now) end
	GM.Broadcast(now)
end

local handlers = {}

function handlers.trail(ply, m, now)
	if G.phase ~= "playing" or not Alive(ply) or type(m.p) ~= "table" then return end
	local e = GM.Entry(ply)
	local a = G.area
	local added = 0
	for k = 1, math.min(#m.p, SNAKE.MAX_POINTS * 3) - 2, 3 do
		local x, y, z = Num(m.p[k]), Num(m.p[k + 1]), Num(m.p[k + 2])
		if x and y and z and (x - a[1]) ^ 2 + (y - a[2]) ^ 2 < (a[4] * 1.5) ^ 2 then
			e.trail[#e.trail + 1] = { x, y, z }
			e.pending[#e.pending + 1] = x
			e.pending[#e.pending + 1] = y
			e.pending[#e.pending + 1] = z
			added = added + 1
		end
	end
	if added > 0 then SNAKE.Trim(e.trail, e.length) end
end

function handlers.crash(ply, m, now)
	if G.phase ~= "playing" then return end
	local by = tonumber(m.by)
	local who = by and by > 0 and Entity(by)
	Out(ply, now, m.wall and "hit the wall" or (IsValid(who) and who ~= ply and ("hit " .. who:Nick() .. "'s tail")) or "hit their own tail")
end

function handlers.eat(ply, m, now)
	if G.phase ~= "playing" or not Alive(ply) then return end
	local id = tonumber(m.id)
	local pellet = id and G.pellets[id]
	local e = GM.Entry(ply)
	local head = e.trail[#e.trail]
	if not (pellet and head) then return end
	if (head[1] - pellet.x) ^ 2 + (head[2] - pellet.y) ^ 2 > (SNAKE.EAT_RADIUS * 3) ^ 2 then return end
	e.length = e.length + SNAKE.GROWTH
	e.eaten = (e.eaten or 0) + 1
	G.pellets[id] = NewPellet(id)
	GM.Broadcast(now)
end

GM = SKATEGM_MODES.Game(SNAKE, {
	freeze = false,
	maxPlayers = SNAKE.MAX_PLAYERS,
	openText = "a game is already set up: join it",
	noGameText = "no game set up",
	entry = function(ply, S)
		local used = {}
		for _, e in pairs(S.entries) do used[e.slot] = true end
		local slot = 1
		while used[slot] do slot = slot + 1 end
		return { slot = slot, length = S.length }
	end,
	resetEntry = function(e) e.playing, e.out, e.place, e.trail, e.pending, e.eaten = nil, nil, nil, nil, nil, nil end,
	publicPlayer = function(p, e)
		return { slot = e.slot, playing = e.playing, out = e.out, length = e.length, eaten = e.eaten or 0, start = e.start, yaw = e.yaw, place = e.place }
	end,
	public = function(S, t)
		t.area = S.area
		t.time, t.length, t.pelletCount = S.time, S.length, S.pelletCount
		t.pellets = S.pellets
		t.winner = S.winner
	end,
	create = function(S, ply, m)
		local x, y, z = Num(m.x, SKATEGM_MODES.FAR), Num(m.y, SKATEGM_MODES.FAR), Num(m.z, SKATEGM_MODES.FAR)
		if not (x and y and z) then return true end
		S.area = { x, y, z, SNAKE.ClampRadius(m.radius) }
		S.time, S.length, S.pelletCount = SNAKE.ClampTime(m.time), SNAKE.ClampLength(m.length), SNAKE.ClampPellets(m.pellets)
		S.pellets = {}
		GM.Entry(ply).length = S.length
	end,
	begin = function(S, now)
		local n = 0
		for _, p in ipairs(S.players) do
			local e = GM.Entry(p)
			e.playing = Skating(p) or nil
			if e.playing then n = n + 1 else GM.Tell(p, "not in Skater mode yet: you sit this one out") end
		end
		if n < 1 then return "nobody's in Skater mode yet" end
		local a, i = S.area, 0
		for _, p in ipairs(S.players) do
			local e = GM.Entry(p)
			if e.playing then
				local ang = i / n * math.pi * 2
				local x, y = a[1] + math.cos(ang) * a[4] * 0.6, a[2] + math.sin(ang) * a[4] * 0.6
				e.start = { x, y, Ground(x, y, a[3]) }
				e.yaw = math.deg(ang) + 90
				e.length, e.trail, e.pending, e.eaten, e.out, e.place = S.length, {}, {}, 0, nil, nil
				SendTrail(p, {}, true)
				i = i + 1
			end
		end
		S.started = n
		S.pellets = {}
		for k = 1, S.pelletCount do S.pellets[k] = NewPellet(k) end
		S.phase, S.deadline, S.winner = "countdown", now + SNAKE.COUNTDOWN, nil
		GM.Broadcast(now)
	end,
	lobby = function(S) S.winner, S.pellets = nil, {} end,
	results = function(S, now, why)
		local best, bestLen
		local alive = AliveList()
		if #alive == 1 and S.started > 1 then
			best = alive[1]
		else
			for _, p in ipairs(alive) do
				local e = GM.Entry(p)
				if not bestLen or e.length > bestLen then best, bestLen = p, e.length end
			end
		end
		if best then
			S.winner = { name = best:Nick(), ent = best:EntIndex() }
			return best:Nick() .. " wins Snake" .. (why and (" (" .. why .. ")") or "")
		end
		S.winner = nil
		return "nobody survived"
	end,
	leaving = function(S, ply, now) if S.phase == "playing" then Out(ply, now, "left") end end,
	tick = {
		countdown = function(S, now)
			if now >= S.deadline then
				S.phase, S.deadline = "playing", now + S.time
				GM.Broadcast(now)
			end
		end,
		playing = function(S, now)
			if now >= S.deadline then return GM.Results(now, "time's up: longest tail") end
			if now >= (S.nextTrail or 0) then
				S.nextTrail = now + 0.15
				for _, p in ipairs(S.players) do
					local e = GM.Entry(p)
					if e.pending and #e.pending > 0 then
						SendTrail(p, e.pending)
						e.pending = {}
					end
				end
			end
		end,
		results = function(S, now) if now >= S.deadline then GM.ToLobby(now) end end,
	},
	handlers = handlers,
})
G = GM.S
SNAKE.Think = GM.Tick
