local S = SkateGM
local R = S.rescue or {}
S.rescue = R
R.SAMPLE = 0.5
R.SETTLED = 0.3
R.BELOW = 256
R.FALLING = 2.5
R.COOLDOWN = 3
R.GROUND = { PhysicsGround = true, SlideGround = true, RevertGround = true, BipedGround = true, GroundAnimation = true }

function R.Bottom()
	if R.bottom ~= nil then return R.bottom or nil end
	local ST = S.stream
	if ST and ST.on and ST.index and ST.index.tiles then
		local low
		for _, t in pairs(ST.index.tiles) do
			for _, info in pairs(t) do
				local z = info.lo and tonumber(info.lo[3])
				if z and (not low or z < low) then low = z end
			end
		end
		R.bottom = low or false
		return low
	end
	local world = game and game.GetWorld and game.GetWorld()
	if IsValid(world) or (world and world.OBBMins) then
		local ok, mins = pcall(world.OBBMins, world)
		if ok and mins then R.bottom = mins.z return mins.z end
	end
	R.bottom = false
	return nil
end

local function Here()
	local p = S.pose and S.pose.pos
	if not p then return nil end
	return Vector(p[1], p[2], p[3])
end

local function Solid(p, down)
	if not (util and util.TraceLine) then return false end
	local tr = util.TraceLine({ start = p + Vector(0, 0, 16), endpos = p - Vector(0, 0, down), mask = MASK_SOLID_BRUSHONLY })
	return tr.Hit and not tr.StartSolid
end

function R.BoardYaw()
	local P = S.P
	local f, b = P and P.TRUCK_FRONT, P and P.TRUCK_BACK
	if not (f and b) then return nil end
	return math.deg(math.atan2(f.y - b.y, f.x - b.x))
end

function R.Think(now)
	if S.phase ~= "on" or not (S.API and S.API.State) then
		R.airSince, R.groundSince = nil, nil
		return
	end
	local p = Here()
	if not p then return end
	local state = S.API.State() or ""
	if R.GROUND[state] then
		R.airSince = nil
		R.groundSince = R.groundSince or now
		if now - R.groundSince >= R.SETTLED and now - (R.sampledAt or 0) >= R.SAMPLE then
			R.sampledAt = now
			local dry = not (S.WATER and S.WATER.state ~= "dry") and not (S.InWater and S.InWater(p + Vector(0, 0, 3)))
			if dry and Solid(p, 48) then
				R.safe = S.ToAbs(p)
				R.safeYaw = R.BoardYaw() or R.safeYaw or 0
			end
		end
		return
	end
	R.groundSince = nil
	R.airSince = R.airSince or now
	if not R.safe or now - (R.rescuedAt or -100) < R.COOLDOWN then return end
	local bottom = R.Bottom()
	local abs = S.ToAbs(p)
	local lost = bottom and abs.z < bottom - R.BELOW
	if not lost and now - R.airSince > R.FALLING and not Solid(p, 32768) then lost = true end
	if lost then R.Rescue(now) end
end

function R.Rescue(now)
	if not (R.safe and S.API and S.API.TeleportTo) then return false end
	R.rescuedAt, R.airSince = now, nil
	R.count = (R.count or 0) + 1
	R.rescuing = true
	local ok = S.API.TeleportTo(S.FromAbs(R.safe), R.safeYaw or 0)
	R.rescuing = nil
	return ok
end

hook.Add("Think", "skategm_rescue", function() R.Think(RealTime()) end)

-- placed somewhere else (a teleport, a minigame's start): the spot before it
-- isn't where to come back to
hook.Add("SkateGMTeleported", "skategm_rescue", function()
	if R.rescuing then return end
	R.safe, R.airSince, R.groundSince = nil, nil, nil
end)
