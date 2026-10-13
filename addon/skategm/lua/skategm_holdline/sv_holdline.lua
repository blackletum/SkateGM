-- Hold the Line, server: the game. Uses only SkateGM.API from the skating add-on.
if not SKATEGM_MODES.Game then include("skategm_modes/sv_game.lua") end

local HL = HOLDLINE
local G, S
local PLAYING = { countdown = true, riding = true, handover = true }

-- the line's over for everyone
function HL.End(reason, ply, now)
	if not PLAYING[S.phase] then return end
	G.Results(now, reason, ply)
end

local function Begin(now)
	S.index = 1
	S.active = S.order[1]
	S.handover = { pos = S.start, yaw = S.yaw, vel = { 0, 0, 0 } }
	S.total, S.passes, S.turns, S.over, S.live, S.startedAt, S.endedAt = 0, 0, 0, nil, nil, nil, nil
	S.phase, S.deadline = "countdown", now + HL.COUNTDOWN
	G.Broadcast(now)
end

-- the line moves on to the next skater, from where it is now
function HL.Pass(ply, pos, yaw, vel, score, now)
	if S.phase ~= "riding" or S.active ~= ply then return end
	local e = G.Entry(ply)
	local got = math.max(0, math.floor(tonumber(score) or 0))
	if e then e.score = (e.score or 0) + got end
	S.total = (S.total or 0) + got
	S.passes, S.turns = (S.passes or 0) + 1, (S.turns or 0) + 1
	S.index = HL.NextIndex(S.index, #S.order)
	S.active = S.order[S.index]
	S.handover = { pos = pos, yaw = yaw, vel = vel }
	S.live = nil
	S.phase, S.deadline = "handover", now + HL.HANDOVER
	G.Broadcast(now)
end

local handlers = {}

local function Clean(m, ply)
	local pos, vel = SKATEGM_MODES.Vec(m.pos), SKATEGM_MODES.Vec(m.vel)
	local yaw = tonumber(m.yaw)
	local at = ply.SkateGMHips
	if not pos or (at and math.sqrt((at.x - pos[1]) ^ 2 + (at.y - pos[2]) ^ 2 + (at.z - pos[3]) ^ 2) > HL.PASS_RANGE) then
		pos = at and { at.x, at.y, at.z } or nil
	end
	if not (yaw and yaw == yaw) then yaw = S.yaw end
	vel = vel or { 0, 0, 0 }
	local speed = math.sqrt(vel[1] ^ 2 + vel[2] ^ 2 + vel[3] ^ 2)
	if speed > HL.SPEED_CAP then vel = { vel[1] / speed * HL.SPEED_CAP, vel[2] / speed * HL.SPEED_CAP, vel[3] / speed * HL.SPEED_CAP } end
	return pos, yaw, vel
end

-- where the line is (a few times a second, from the skater holding it)
function handlers.live(ply, m, now)
	if S.phase ~= "riding" or S.active ~= ply then return end
	local pos, yaw, vel = Clean(m, ply)
	if pos then S.live = { pos = pos, yaw = yaw, vel = vel, score = tonumber(m.score) or 0 } end
end

-- my time's up and I'm rolling: the line goes on from here
function handlers.pass(ply, m, now)
	if S.phase ~= "riding" or S.active ~= ply or now < S.deadline - 0.5 then return end
	local pos, yaw, vel = Clean(m, ply)
	if not pos then return end
	HL.Pass(ply, pos, yaw, vel, m.score, now)
end

function handlers.bail(ply, m, now)
	if S.phase ~= "riding" or S.active ~= ply then return end
	HL.End("bail", ply, now)
end

function handlers.stall(ply, m, now)
	if S.phase ~= "riding" or S.active ~= ply or (S.minSpeed or 0) <= 0 then return end
	HL.End("stall", ply, now)
end

G = SKATEGM_MODES.Game(HL, {
	freeze = false,
	canJoin = function(S) if S.phase ~= "lobby" then return "a line is going: wait for the next one" end end,
	entry = function() return { score = 0 } end,
	resetEntry = function(e) e.playing, e.score = nil, 0 end,
	publicPlayer = function(p, e) return { playing = e.playing or nil, score = e.score or 0 } end,
	public = function(S, t, now)
		t.start, t.yaw, t.turnTime, t.minSpeed = S.start, S.yaw, S.turnTime, S.minSpeed
		t.active = G.Ent(S.active)
		t.handover = S.handover
		t.total, t.passes, t.turns = S.total or 0, S.passes or 0, S.turns or 0
		t.lineTime = S.startedAt and math.floor(((S.endedAt or now) - S.startedAt) * 10 + 0.5) / 10 or 0
		t.over, t.best = S.over, S.best
		local nextUp = S.order and S.order[HL.NextIndex(S.index or 1, #S.order)]
		t.nextUp = G.Ent(nextUp)
	end,
	create = function(S, ply, m)
		local p, startYaw = SKATEGM_MODES.HostStart(ply, m)
		S.start, S.yaw = { p.x, p.y, p.z }, startYaw
		S.turnTime, S.minSpeed = HL.ClampTurn(m.turnTime), HL.MinSpeed(m.minSpeed)
		S.total, S.passes, S.turns = 0, 0, 0
	end,
	begin = function(S, now)
		S.order = {}
		for _, p in ipairs(S.players) do
			S.order[#S.order + 1] = p
			local e = G.Entry(p)
			e.playing, e.score = true, 0
		end
		Begin(now)
	end,
	lobby = function(S)
		S.handover, S.order, S.index, S.over, S.live = nil, nil, nil, nil, nil
		S.total, S.passes, S.turns, S.startedAt, S.endedAt = 0, 0, 0, nil, nil
	end,
	results = function(S, now, reason, ply)
		S.endedAt = now
		S.over = { reason = reason, name = IsValid(ply) and ply:Nick() or nil }
		local line = S.total or 0
		if not S.best or line > S.best.total or (line == S.best.total and (S.passes or 0) > S.best.passes) then
			S.best = { total = line, passes = S.passes or 0 }
		end
		S.handover = nil
		local why = reason == "bail" and ((S.over.name or "someone") .. " bailed")
			or reason == "stall" and ("the line slowed to a stop with " .. (S.over.name or "someone"))
			or reason == "left" and ((S.over.name or "someone") .. " left mid-line") or "the line ended"
		return string.format("%s: %s points, %d handover%s", why, SKATEGM_MODES.Commas(line), S.passes or 0, S.passes == 1 and "" or "s")
	end,
	removed = function(S, ply, now)
		if not S.order then return end
		local k = SKATEGM_MODES.IndexOf(S.order, ply)
		if k then
			table.remove(S.order, k)
			if k < S.index then S.index = S.index - 1 end
			if #S.order == 0 then HL.End("left", ply, now) return true end
			if S.index > #S.order then S.index = 1 end
		end
		if S.active == ply and PLAYING[S.phase] then HL.End("left", ply, now) return true end
	end,
	tick = {
		countdown = function(S, now) HL.Go(now) end,
		handover = function(S, now) HL.Go(now) end,
		riding = function(S, now)
			-- (no pass from the skater well after their time: pass from the last place they reported)
			if now > S.deadline + HL.PASS_WAIT then
				local l = S.live
				local at = IsValid(S.active) and S.active.SkateGMHips
				if l then return HL.Pass(S.active, l.pos, l.yaw, l.vel, l.score, now) end
				if at then return HL.Pass(S.active, { at.x, at.y, at.z }, S.yaw, { 0, 0, 0 }, 0, now) end
				return HL.End("left", S.active, now)
			end
		end,
	},
	handlers = handlers,
})
S = G.S

function HL.Go(now)
	if now <= S.deadline then return end
	if not IsValid(S.active) or not G.IndexOf(S.active) then return HL.End("left", S.active, now) end
	S.phase, S.deadline = "riding", now + S.turnTime
	S.startedAt = S.startedAt or now
	G.Broadcast(now)
end
