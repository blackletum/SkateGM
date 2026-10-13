-- Board Golf, server: the game. Uses only SkateGM.API from the skating add-on.
if not SKATEGM_MODES.Game then include("skategm_modes/sv_game.lua") end

local BG = BOARDGOLF
local G, S

local function DropBall()
	if IsValid(S.board) then S.board:Remove() end
	S.board, S.stillSince = nil, nil
end
BG.DropBall = DropBall

local function Stroke(ply, pos, how, now) return BG.Stroke(ply, pos, how, now) end

G = SKATEGM_MODES.Game(BG, {
	entry = function() return { strokes = 0 } end,
	resetEntry = function(e) e.strokes, e.holed, e.lie, e.playing, e.picked = 0, nil, nil, nil, nil end,
	publicPlayer = function(p, e)
		return { strokes = e.strokes or 0, holed = e.holed or nil, lie = e.lie, playing = e.playing or nil, picked = e.picked or nil }
	end,
	public = function(S, t)
		t.tee, t.cup, t.yaw = S.tee, S.cup, S.yaw
		t.cupSize, t.radius, t.shotTime, t.maxStrokes, t.par = S.cupSize, S.radius, S.shotTime, S.maxStrokes, S.par
		t.friction = S.friction
		t.last, t.winners = S.last, S.winners
		t.board = IsValid(S.board) and S.board:EntIndex() or nil
	end,
	hosting = function(S, ply) return ply:Nick() .. " is hosting Board Golf (par " .. S.par .. "): join with LB + D-pad left" end,
	create = function(S, ply, m)
		local cup = SKATEGM_MODES.Vec(m.cup)
		if not cup then return "place the cup first" end
		local p = SKATEGM_MODES.HostStart(ply, m)
		S.index, S.round = nil, nil
		S.tee = Vector(p.x, p.y, p.z)
		S.cup = cup
		S.yaw = BG.YawTo(S.tee, cup)
		S.cupSize, S.shotTime, S.maxStrokes = BG.CupId(m.cupSize), BG.ClampShot(m.shotTime), BG.ClampStrokes(m.maxStrokes)
		S.radius = m.radius and BG.ClampRadius(m.radius) or BG.CupRadius(S.cupSize)
		S.par = BG.ParChoice(m.par) > 0 and BG.ParChoice(m.par) or BG.Par(BG.Distance(S.tee, cup))
		S.friction = BG.Friction(m.friction)
	end,
	begin = function(S, now)
		S.order, S.index, S.round = nil, nil, nil
		for _, e in pairs(S.entries) do
			e.playing, e.strokes, e.holed, e.picked = true, 0, nil, nil
			e.lie = Vector(S.tee[1], S.tee[2], S.tee[3])
		end
		S.phase, S.deadline = "flyover", now + BG.FlyTime(BG.Distance(S.tee, S.cup))
		G.Broadcast(now)
	end,
	lobby = function(S)
		DropBall()
		S.winners, S.index, S.round = nil, nil, nil
	end,
	stop = function() DropBall() end,
	results = function(S)
		local best, names = nil, {}
		for _, p in ipairs(S.players) do
			local e = S.entries[G.Key(p)]
			if e.playing then
				if not best or e.strokes < best then best, names = e.strokes, { p:Nick() } elseif e.strokes == best then names[#names + 1] = p:Nick() end
			end
		end
		S.winners = { names = names, strokes = best or 0 }
		return #names > 0 and (table.concat(names, " and ") .. " win" .. (#names == 1 and "s" or "") .. " in " .. best .. " (par " .. S.par .. ")") or "nobody finished"
	end,
	turns = {
		live = { "shot", "roll" },
		nextUp = false,
		time = function(S) return S.shotTime + BG.RELEASE_GRACE end,
		skipText = " couldn't get to their lie in time: a stroke",
		skip = function(S, p, now)
			S.phase = "shot"
			Stroke(p, nil, "skipped", now)
		end,
		pick = function(S)
			DropBall()
			local list = {}
			for _, p in ipairs(S.players) do
				local e = S.entries[G.Key(p)]
				if e.playing then list[#list + 1] = { ply = p, holed = e.holed, lie = e.lie } end
			end
			local up = BG.NextUp(list, S.cup)
			return up and up.ply
		end,
		left = function() DropBall() end,
	},
	offSkate = { during = { "shot" }, action = function(S, p, now) Stroke(p, nil, "left", now) end },
	tick = {
		flyover = function(S, now) if now > S.deadline then G.Next(now) end end,
		shot = function(S, now) if now > S.deadline then Stroke(S.active, nil, "lost", now) end end,
		roll = function(S, now)
			local ball = S.board
			if not IsValid(ball) then return Stroke(S.active, nil, "lost", now) end
			local p = SkateGMEntAbs(ball)
			if S.sinkAt then
				if now - S.sinkAt >= BG.SINK_TIME then Stroke(S.active, { S.cup[1], S.cup[2], S.cup[3] }, "lie", now) end
				return
			end
			if BG.InCup({ p.x, p.y, p.z }, S.cup, S.radius) and ball:Speed() < BG.CAPTURE_SPEED then
				S.sinkAt = now
				if ball.Sink then ball:Sink(Vector(S.cup[1], S.cup[2], S.cup[3])) end
				return
			end
			if ball:Speed() < BG.REST_SPEED then S.stillSince = S.stillSince or now else S.stillSince = nil end
			if (S.stillSince and now - S.stillSince >= BG.REST_TIME) or now > S.deadline then
				Stroke(S.active, { p.x, p.y, p.z }, "lie", now)
			end
		end,
	},
	handlers = {
		-- the shot clock ran out (or B): my board, as it is, goes on as the ball
		release = function(ply, m, now)
			if S.phase ~= "shot" or S.active ~= ply then return end
			local pos, ang, vel = SKATEGM_MODES.Vec(m.pos), SKATEGM_MODES.Vec(m.ang), SKATEGM_MODES.Vec(m.vel)
			local at = ply.SkateGMHips
			if not pos or (at and math.sqrt((at.x - pos[1]) ^ 2 + (at.y - pos[2]) ^ 2 + (at.z - pos[3]) ^ 2) > BG.RELEASE_RANGE) then
				pos = at and { at.x, at.y, at.z } or nil
			end
			if not pos then return Stroke(ply, nil, "lost", now) end
			local v = vel and Vector(vel[1], vel[2], vel[3]) or Vector(0, 0, 0)
			if v:Length() > BG.SPEED_MAX then v = v:GetNormalized() * BG.SPEED_MAX end
			local ball = ents.Create("skategm_golfboard")
			if not IsValid(ball) then return Stroke(ply, { pos[1], pos[2], pos[3] }, "lie", now) end
			SkateGMPlace(ball, Vector(pos[1], pos[2], pos[3] + 3))
			ball:SetAngles(ang and Angle(ang[1], ang[2], ang[3]) or Angle(0, S.yaw or 0, 0))
			ball:SetSkater(ply)
			ball:Spawn()
			ball:Launch(v, S.friction)
			S.board, S.stillSince, S.sinkAt = ball, nil, nil
			S.phase, S.deadline = "roll", now + BG.SETTLE
			G.Broadcast(now)
		end,
	},
})
S = G.S
BG.NextShot = G.Next

-- the active player's stroke is over: the board rests at pos (nil: it didn't count where it went)
function BG.Stroke(ply, pos, how, now)
	if S.active ~= ply or not (S.phase == "shot" or S.phase == "roll") then return end
	if IsValid(S.board) then
		local phys = S.board:GetPhysicsObject()
		if IsValid(phys) then phys:EnableMotion(false) end
	end
	local e = G.Entry(ply)
	e.strokes = e.strokes + 1
	local result = how or "lie"
	if pos then
		if BG.InCup(pos, S.cup, S.radius) then
			e.holed, result = true, "holed"
		else
			e.lie = pos
		end
	end
	if not e.holed and e.strokes >= S.maxStrokes then
		e.strokes, e.holed, e.picked, result = S.maxStrokes + BG.PICKUP, true, true, "picked"
	end
	S.last = { name = ply:Nick(), ent = ply:EntIndex(), strokes = e.strokes, result = result,
		distance = (not e.holed) and math.floor(BG.Distance(e.lie, S.cup) + 0.5) or nil }
	G.EndTurn(now)
	if result == "holed" then G.TellGame(string.format("%s holed out in %d!", ply:Nick(), e.strokes))
	elseif result == "picked" then G.TellGame(ply:Nick() .. " picked up (" .. e.strokes .. ")") end
end
