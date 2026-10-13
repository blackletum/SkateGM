dofile("gmock.lua")
local frozenCalls = {}
skategm = { SetFrozen = function(v) frozenCalls[#frozenCalls + 1] = v end, SetInputBlocked = function() end }
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM
local A = S.API
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
A.Freeze(true, "ui")
A.Freeze(true, "boardgolf")
A.Freeze(false, "ui")
check("two holds on the skater, one lets go: still frozen", A.IsFrozen() and frozenCalls[#frozenCalls] == 1)
A.Freeze(false, "boardgolf")
check("... both let go: free", not A.IsFrozen() and frozenCalls[#frozenCalls] == 0)
A.Freeze(true)
A.Freeze(false)
check("an old caller without a reason still works", not A.IsFrozen())
A.BlockInput(true, "menu")
A.BlockInput(true, "spectate")
A.BlockInput(false, "menu")
check("input blocks work the same way", S.inputBlocked == true)
A.BlockInput(false, "spectate")
check("... and clear when the last one lets go", not S.inputBlocked)
dofile("../../addon/skategm/lua/skategm_ui/cl_pad.lua")
local UI = SKATEGM_UI
local playing = false
SKATEGM_MODES = { Playing = function() return playing end }
UI.Take("settings", {})
check("a menu in free skate: the skater stops", A.IsFrozen())
UI.Give("settings")
playing = true
UI.Take("settings", {})
check("a menu during a minigame: the skater keeps going", not A.IsFrozen())
UI.Give("settings")
playing = false
UI.Take("minigames", {})
playing = true
UI.Think(1, 0.016)
check("a minigame starts while the menu has me stopped: let go", not A.IsFrozen())
UI.Give("minigames")

do
	local S = SkateGM
	local trace = util.TraceLine
	util.TraceLine = function(t) return { Hit = true, HitPos = Vector(t.start.x, t.start.y, 100), HitNormal = Vector(0, 0, 1) } end
	local _, _, z = S.LandOn(5, 6, 100)
	local _, _, z2 = S.LandOn(5, 6, 99.5)
	local _, _, z3 = S.LandOn(5, 6, 300)
	util.TraceLine = trace
	print(string.format("%-72s %s", "every teleport lands just above the ground under it, never below", (z == 100 + S.LAND_CLEAR and z2 == 100 + S.LAND_CLEAR and z3 == 300) and "OK" or "<-- WRONG"))
end

local heard
local runHook = hook.Run
hook.Run = function(name, delta) if name == "SkateGMFrameShifted" then heard = delta end end
local frame
S.frameOffset = function() return frame end
S.lastFrame = nil
S.FrameThink()
frame = Vector(8192, 0, 0)
S.FrameThink()
check("the frame moving out of cell 0 (no offset before) is heard, by how much", heard and heard.x == 8192)
heard = nil
frame = nil
S.FrameThink()
check("... and back into cell 0 too", heard and heard.x == -8192)
hook.Run = runHook
S.frameOffset = nil

A.Freeze(true, "race_hold")
check("a hold can be asked about by name", A.HeldBy("race_hold") and not A.HeldBy("other"))
S.phase = "on"
S.SetHidden("view", true)
S.Leave(false)
check("leaving Skater mode lets every hold go, in the module too", not A.IsFrozen() and frozenCalls[#frozenCalls] == 0 and not A.HeldBy("race_hold"))
check("... and isn't hidden next time", next(S.hiddenWhy) == nil and S.phase == "off")

check("a module without an API level is too old for this add-on", S.ModuleTooOld({}) == true)
check("... one at the level it needs isn't", S.ModuleTooOld({ ApiLevel = function() return S.MODULE_API end }) == false)
check("... nor a newer one", S.ModuleTooOld({ ApiLevel = function() return S.MODULE_API + 1 end }) == false)
