-- S.K.A.T.E., server: the game. Uses only SkateGM.API from the skating add-on.
if not SKATEGM_MODES.Game then include("skategm_modes/sv_game.lua") end

local G, S

local function Alive(ply)
	local e = IsValid(ply) and G.IndexOf(ply) and G.Entry(ply)
	return e ~= nil and e ~= false and not e.out
end

local function AliveList()
	local out = {}
	for _, p in ipairs(S.order or {}) do if Alive(p) then out[#out + 1] = p end end
	return out
end

-- the next setter after p in the order who's still in
local function NextSetter(p)
	local order = S.order
	local i = SKATEGM_MODES.IndexOf(order, p) or 0
	for k = 1, #order do
		local q = order[(i - 1 + k) % #order + 1]
		if Alive(q) and q ~= p then return q end
	end
	return Alive(p) and p or nil
end

-- who has to match the set: everyone still in after the setter, in order
local function Matchers(setter)
	local out, order = {}, S.order
	local i = SKATEGM_MODES.IndexOf(order, setter) or 0
	for k = 1, #order - 1 do
		local q = order[(i - 1 + k) % #order + 1]
		if Alive(q) and q ~= setter then out[#out + 1] = q end
	end
	return out
end

local function Continue(now)
	if #AliveList() <= 1 then return G.Results(now) end
	G.EndTurn(now)
end

local function Fail(ply, now) return SKATE.Result(ply, false, {}, now) end

G = SKATEGM_MODES.Game(SKATE, {
	minPlayers = 2,
	entry = function() return { letters = 0 } end,
	resetEntry = function(e) e.letters, e.out = 0, nil end,
	publicPlayer = function(p, e) return { letters = e.letters or 0, out = e.out or nil } end,
	public = function(S, t)
		t.spot = { S.spot.x, S.spot.y, S.spot.z }
		t.yaw, t.time = S.yaw, S.time
		t.setter, t.set = G.Ent(S.setter), S.set
		t.last, t.winner = S.last, S.winner
	end,
	create = function(S, ply, m)
		S.spot, S.yaw = SKATEGM_MODES.HostStart(ply, m)
		S.time = SKATE.ClampTime(m.time)
	end,
	begin = function(S)
		for i = #S.order, 2, -1 do
			local j = math.random(1, i)
			S.order[i], S.order[j] = S.order[j], S.order[i]
		end
		for _, e in pairs(S.entries) do e.letters, e.out = 0, nil end
		S.setter, S.set, S.queue = S.order[1], nil, nil
	end,
	lobby = function(S) S.setter, S.set, S.queue, S.winner = nil, nil, nil, nil end,
	results = function(S)
		local alive = AliveList()
		S.winner = alive[1] and { name = alive[1]:Nick(), ent = alive[1]:EntIndex() } or nil
		return S.winner and (S.winner.name .. " wins S.K.A.T.E.!") or "nobody's left"
	end,
	removed = function(S, ply, now, wasActive)
		if S.queue then
			local q = SKATEGM_MODES.IndexOf(S.queue, ply)
			if q then table.remove(S.queue, q) end
		end
		if not SKATEGM_MODES.InPlay(S) then return end
		if S.setter == ply then
			S.setter = NextSetter(ply)
			if not wasActive then S.set, S.queue = nil, nil end
		end
		if wasActive then
			S.last = { name = ply:Nick(), how = "left" }
			Continue(now)
			return true
		end
		if #AliveList() <= 1 then
			G.Results(now)
			return true
		end
	end,
	turns = {
		single = true,
		nextUp = false,
		keepOrder = true,
		live = { "attempt", "finish" },
		skip = function(S, p, now) SKATE.Resolve(p, false, {}, now) end,
		pick = function(S)
			if #AliveList() <= 1 then return nil end
			while S.set and S.queue and #S.queue > 0 do
				local p = table.remove(S.queue, 1)
				if Alive(p) then return p end
			end
			S.set, S.queue = nil, nil
			if not Alive(S.setter) then S.setter = NextSetter(S.setter) end
			return S.setter
		end,
	},
	offSkate = { during = { "attempt", "finish" }, action = function(S, p, now) Fail(p, now) end },
	tick = {
		attempt = function(S, now)
			if now > S.deadline then
				S.phase, S.deadline = "finish", now + SKATE.FINISH
				G.Broadcast(now)
			end
		end,
		finish = function(S, now) if now > S.deadline then Fail(S.active, now) end end,
	},
	handlers = {
		attempt = function(ply, m, now) SKATE.Result(ply, m.landed == true, m.tricks, now) end,
	},
})
S = G.S

function SKATE.Result(ply, landed, tricks, now)
	if S.active ~= ply or not G.Live() then return end
	SKATE.Resolve(ply, landed, tricks, now)
end

function SKATE.Resolve(ply, landed, tricks, now)
	tricks = SKATE.Clean(tricks)
	local name = ply:Nick()
	if not S.set then
		if landed and #tricks > 0 then
			S.set, S.queue = tricks, Matchers(ply)
			S.last = { name = name, ent = ply:EntIndex(), how = "set", set = tricks }
			G.TellGame(name .. " set: " .. table.concat(tricks, " + "))
		else
			S.last = { name = name, ent = ply:EntIndex(), how = "missed the set" }
			S.setter = NextSetter(ply)
		end
		return Continue(now)
	end
	local e = G.Entry(ply)
	local matched = landed and SKATE.Matches(S.set, tricks)
	if not matched then
		e.letters = (e.letters or 0) + 1
		if e.letters >= #SKATE.WORD then e.out = true end
	end
	S.last = { name = name, ent = ply:EntIndex(), how = matched and "matched" or "missed", letters = SKATE.Letters(e.letters), out = e.out or nil }
	if not matched then G.TellGame(string.format("%s missed: %s%s", name, SKATE.Letters(e.letters), e.out and " - out!" or "")) end
	Continue(now)
end
