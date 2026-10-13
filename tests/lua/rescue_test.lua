dofile("gmock.lua")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end

hook = { Add = function() end }
function IsValid(x) return x ~= nil end
local floor = 0
util = util or {}
util.TraceLine = function(t)
	if t.endpos.z <= floor and t.start.z >= floor then return { Hit = true, HitPos = Vector(t.start.x, t.start.y, floor), HitNormal = Vector(0, 0, 1) } end
	return { Hit = false }
end
function EyeAngles() return Angle(0, 90, 0) end
local state, tele = "PhysicsGround", nil
SkateGM = {
	phase = "on",
	pose = { pos = { 100, 200, 0 } },
	P = { TRUCK_FRONT = Vector(100, 210, 0), TRUCK_BACK = Vector(100, 190, 0) },
	API = { State = function() return state end, TeleportTo = function(p, yaw) tele = { p, yaw } return true end },
	ToAbs = function(v) return v end, FromAbs = function(v) return v end,
	stream = { on = true, index = { tiles = { ["0 0"] = { ["0"] = { lo = { 0, 0, -500 }, hi = { 1, 1, 9000 } } } } } },
}
local S = SkateGM
dofile("../../addon/skategm/lua/skategm/cl_rescue.lua")
local R = S.rescue

R.Think(0) R.Think(0.4) R.Think(0.9)
check("riding on solid ground: the spot is kept as safe", R.safe and R.safe.x == 100 and R.safe.y == 200)
state = "PhysicsAir"
S.pose.pos = { 300, 200, 400 }
R.Think(1.0)
check("in the air over the map: nothing happens", tele == nil)
S.pose.pos = { 300, 200, -800 }
R.Think(1.1)
check("below everything the map has: put back on the safe spot, facing the board's way", tele and tele[1].x == 100 and tele[1].y == 200 and math.abs(tele[2] - 90) < 1e-6)
tele = nil
R.Think(1.2)
check("... once, not every frame", tele == nil)
floor = -100000
S.pose.pos = { 300, 200, 100 }
R.rescuedAt = -100
R.airSince = nil
R.Think(10)
R.Think(11)
check("falling with nothing under you: not straight away", tele == nil)
R.Think(13)
check("... but after a couple of seconds", tele ~= nil)
tele = nil
state = "WipeoutGround"
floor = 0
R.rescuedAt, R.airSince = -100, nil
S.pose.pos = { 300, 200, 5 }
R.Think(20) R.Think(30)
check("lying in a bail on the ground: left alone", tele == nil)
