dofile("gmock.lua")
local cv = { skategm_rumble = "1", skategm_rumble_strength = "1" }
function CreateClientConVar(n, d)
	return { GetBool = function() return (cv[n] or d) ~= "0" end, GetFloat = function() return tonumber(cv[n] or d) end }
end
local hooks = {}
hook = { Add = function(ev, id, f) hooks[ev .. "/" .. id] = f end }
local sent = {}
skategm = { Rumble = function(l, h, s) sent[#sent + 1] = { l, h, s } end }
SkateGM = { phase = "on" }
local S = SkateGM
dofile("../../addon/skategm/lua/skategm/cl_rumble.lua")
local RU = S.rumble
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local function last() return sent[#sent] end

RU.Think(0)
check("nothing happening: nothing sent", #sent == 0)
S.RumbleEvents({ vz = 120, speed = 300 }, "ground", "air", 1)
RU.Think(1)
check("a pop: a short light buzz", last() and last()[2] > last()[1] and last()[2] <= 0.35 and last()[3] == RU.HOLD)
RU.Think(1.2)
check("... gone after its time: a stop is sent", last()[1] == 0 and last()[2] == 0 and last()[3] == 0)
local n = #sent
RU.Think(1.3)
check("... once", #sent == n)
S.RumbleEvents({ minVz = -600, speed = 300 }, "air", "ground", 2)
RU.Think(2)
local hard = last()[1]
S.RumbleEvents({ minVz = -150, speed = 300 }, "air", "ground", 3)
RU.Think(3)
check("landings: harder ones rumble harder", hard > 0.9 and last()[1] < 0.4 and last()[1] > 0)
RU.Think(4)
S.RumbleEvents({ minVz = -50, speed = 300 }, "air", "ground", 5)
RU.Think(5)
check("a soft touch-down: none", last()[1] == 0)
S.RumbleEvents({ speed = 600 }, "ground", "metalgrind", 6)
RU.Think(6)
RU.Think(6.5)
check("grinding: a steady buzz while it lasts", last()[2] >= 0.12 and last()[3] == RU.HOLD)
local count = #sent
RU.Think(6.51)
check("... not sent every frame", #sent == count)
RU.Think(6.7)
check("... kept alive before it runs out", #sent == count + 1)
S.RumbleEvents({ speed = 600 }, "metalgrind", "ground", 7)
RU.Think(7)
check("off the rail: stops", last()[1] == 0 and last()[2] == 0)
S.RumbleEvents({ speed = 0 }, "ground", "wipeout", 8)
RU.Think(8)
check("a bail: strong", last()[1] > 0.8)
cv.skategm_rumble_strength = "0.5"
RU.Think(8.05)
check("... at the strength setting", last()[1] < 0.5)
cv.skategm_rumble = "0"
RU.Think(8.1)
check("Rumble off: stops", last()[1] == 0 and last()[2] == 0)
cv.skategm_rumble, cv.skategm_rumble_strength = "1", "1"
S.rocketOn = true
RU.Think(9)
check("the rocket firing: a steady low rumble", last()[1] >= 0.2)
gui = { IsGameUIVisible = function() return true end }
RU.Think(9.05)
check("the game's menu open (paused): stops", last()[1] == 0 and last()[2] == 0)
gui = nil
S.phase = "off"
RU.Think(9.1)
check("not skating: stops, and pending pulses dropped", last()[1] == 0 and #RU.pulses == 0)
S.rocketOn = nil
check("the hooks are in", hooks["Think/skategm_rumble"] and hooks["ShutDown/skategm_rumble"])
