---------------------------------------------------------------------------
-- The map (LB + Y while skating): the map seen from straight above. Left
-- stick pans, triggers zoom, D-pad up / down moves the cut (everything above
-- it is left out, so roofs don't hide what's under them). The glowing dot is
-- where you'd go: A teleports you there, B goes back.
---------------------------------------------------------------------------
if not (SKATEGM_UI and SKATEGM_UI.pad) then include("skategm_ui/cl_pad.lua") end
local UI = SKATEGM_UI
local PAD = UI.pad
local B = PAD.B
local MAP = UI.map or {}
UI.map = MAP
MAP.ZOOM_MIN, MAP.ZOOM_MAX, MAP.ZOOM_DEFAULT = 256, 16384, 1536
MAP.PAN = 1.3 -- screen widths a second at full stick
MAP.CUT_ABOVE, MAP.CUT_STEP = 320, 128
MAP.ZOOM_DISTRICT = 4096
MAP.CUT_TOP = 16384

local function MyPos()
	local a = PAD.API()
	local p = a and a.SkaterPos and a.SkaterPos()
	return p or (LocalPlayer and IsValid(LocalPlayer()) and LocalPlayer():GetPos()) or Vector(0, 0, 0)
end

-- a minigame being played keeps you where you are
function MAP.CanTeleport()
	local M = SKATEGM_MODES
	return not (M and M.Playing and M.Playing())
end

function MAP.TopCut(p)
	local ST = SkateGM and SkateGM.stream
	if ST and ST.on and ST.TopZ and ST.TopZ() then return ST.TopZ() - ST.Frame().z + MAP.CUT_ABOVE end
	local tr = util.TraceLine({ start = p + Vector(0, 0, 16), endpos = p + Vector(0, 0, 32768), mask = MASK_SOLID_BRUSHONLY })
	if tr.Hit and tr.HitSky then return tr.HitPos.z - 8 end
	if tr.Hit then return math.max(p.z + MAP.CUT_ABOVE, tr.HitPos.z - 8) end
	return p.z + MAP.CUT_TOP
end

function MAP.Open()
	if UI.Busy() then return end
	local p = MyPos()
	MAP.centre = Vector(p.x, p.y, 0)
	MAP.top = MAP.TopCut(p)
	MAP.cut = MAP.top
	MAP.zoom = MAP.ZOOM_DEFAULT
	MAP.target, MAP.note = nil, nil
	local list, ST = MAP.Districts()
	MAP.district = list and (ST.Here() or 1) or nil
	UI.Take("map", { press = MAP.Press, think = MAP.Think }, function(_, _, fov) return MAP.View(fov) end)
end

function MAP.Close()
	local ST = SkateGM and SkateGM.stream
	if ST and ST.SetFocus then ST.SetFocus(nil) end
	UI.Give("map")
end
function MAP.Active() return UI.IsOpen("map") end

-- straight down, orthographic: the camera sits at the cut, so whatever is
-- above it is behind the camera and isn't drawn
function MAP.View(fov)
	if not MAP.Active() then return nil end
	local aspect = ScrW() / math.max(1, ScrH())
	local half = MAP.zoom
	return {
		origin = Vector(MAP.centre.x, MAP.centre.y, MAP.cut),
		angles = Angle(90, 90, 0),
		fov = fov,
		znear = 1,
		zfar = 65536,
		ortho = { left = -half * aspect, right = half * aspect, top = -half, bottom = half },
	}
end

-- where the dot is: the first floor under the cut at the centre
function MAP.FindTarget()
	local from = Vector(MAP.centre.x, MAP.centre.y, MAP.cut)
	local ST = SkateGM and SkateGM.stream
	if ST and ST.on then return ST.FloorBelow(from) end
	local tr = util.TraceLine({ start = from, endpos = from - Vector(0, 0, 65536), mask = MASK_PLAYERSOLID_BRUSHONLY or MASK_SOLID_BRUSHONLY })
	if tr.Hit and not tr.HitSky and not tr.StartSolid and tr.HitNormal.z > 0.6 then return tr.HitPos end
	return nil
end

function MAP.Teleport()
	if not MAP.target then
		MAP.note = { text = "Nowhere to stand there", t = RealTime() }
		return false
	end
	if not MAP.CanTeleport() then
		MAP.note = { text = "Not during a minigame", t = RealTime() }
		return false
	end
	local a = PAD.API()
	local at = MAP.target + Vector(0, 0, 4)
	local yaw = (a and a.View and a.View() and a.View().angles and a.View().angles.y) or 0
	MAP.Close()
	if a and a.TeleportTo then a.TeleportTo(at, yaw) end
	return true
end

-- streamed maps hold several districts: X goes to the next one
function MAP.Districts()
	local ST = SkateGM and SkateGM.stream
	local list = ST and ST.Districts and ST.Districts()
	return list and #list > 1 and list or nil, ST
end

function MAP.NextDistrict()
	local list, ST = MAP.Districts()
	if not list then return false end
	MAP.district = (MAP.district or ST.Here() or 0) % #list + 1
	local d = list[MAP.district]
	local o = ST.Frame()
	local sp = d.spawn
	MAP.centre = Vector(sp[1] - o.x, sp[2] - o.y, 0)
	MAP.cut = MAP.top or MAP.TopCut(Vector(MAP.centre.x, MAP.centre.y, sp[3] - o.z))
	MAP.loadingSince = RealTime()
	MAP.zoom = math.max(MAP.zoom, MAP.ZOOM_DISTRICT)
	MAP.target, MAP.note = nil, nil
	return true
end

function MAP.DistrictTitle()
	local list = MAP.Districts()
	local d = list and MAP.district and list[MAP.district]
	return d and d.title or nil
end

function MAP.Press(btn)
	if btn == B.X then MAP.NextDistrict()
	elseif btn == B.A then MAP.Teleport()
	elseif btn == B.B then MAP.Close()
	elseif btn == B.UP then MAP.cut = math.min(MAP.top or math.huge, MAP.cut + MAP.CutStep())
	elseif btn == B.DOWN then MAP.cut = MAP.cut - MAP.CutStep()
	end
end

function MAP.CutStep()
	local ground = MAP.target and MAP.target.z or MyPos().z
	return math.max(MAP.CUT_STEP, math.floor((MAP.cut - ground) / 4 / MAP.CUT_STEP) * MAP.CUT_STEP)
end

function MAP.Think(pad, now, dt)
	local speed = MAP.zoom * 2 * MAP.PAN * dt
	MAP.centre = MAP.centre + Vector(PAD.Dead(pad.lx), PAD.Dead(pad.ly), 0) * speed
	local z = (pad.lt or 0) - (pad.rt or 0)
	if z ~= 0 then MAP.zoom = math.Clamp(MAP.zoom * math.exp(z * 1.6 * dt), MAP.ZOOM_MIN, MAP.ZOOM_MAX) end
	MAP.target = MAP.FindTarget()
	local ST = SkateGM and SkateGM.stream
	if ST and ST.on and ST.SetFocus then ST.SetFocus(Vector(MAP.centre.x, MAP.centre.y, MAP.cut) + ST.Frame()) end
end

UI.Combo(B.Y, { open = MAP.Open, label = "map" })

---------------------------------------------------------------------------
-- drawing
---------------------------------------------------------------------------
local GLOW, WHITE, RED, CYAN = nil, PAD.WHITE, Color(255, 90, 80), PAD.BLUE

function MAP.Legend()
	local rows = {
		{ keys = { "LS" }, text = "Move around" },
		{ keys = { "LT", "RT" }, text = "Zoom out / in" },
		{ keys = { "UP", "DOWN" }, text = "Cut higher / lower" },
		{ keys = { "A" }, text = "Go there", lit = MAP.target ~= nil and MAP.CanTeleport() },
		{ keys = { "B" }, text = "Back" },
	}
	if MAP.Districts() then table.insert(rows, #rows, { keys = { "X" }, text = "Next district" }) end
	return rows
end

function MAP.DrawWorld()
	if not MAP.Active() then return end
	GLOW = GLOW or Material("sprites/light_glow02_add")
	render.SetMaterial(GLOW)
	local size = MAP.zoom * 0.06
	if MAP.target then
		local pulse = 0.75 + 0.25 * math.sin(RealTime() * 5)
		render.DrawSprite(MAP.target + Vector(0, 0, 2), size * 1.6 * pulse, size * 1.6 * pulse, CYAN)
		render.DrawSprite(MAP.target + Vector(0, 0, 3), size * 0.5, size * 0.5, WHITE)
	end
	-- me, and everyone else skating
	render.DrawSprite(MyPos() + Vector(0, 0, 40), size, size, Color(90, 255, 140))
	local a = PAD.API()
	for _, ply in ipairs(a and a.Skaters and a.Skaters() or {}) do
		local P = a.PoseOf and a.PoseOf(ply)
		if P and P.HIPS then render.DrawSprite(P.HIPS + Vector(0, 0, 40), size, size, Color(255, 200, 70)) end
	end
end

function MAP.Title()
	local map = game and game.GetMap and game.GetMap() or ""
	local title = GetGlobal2String and GetGlobal2String("SkateGMTitle", "") or ""
	if MAP.titleFor ~= map .. "\n" .. title then
		MAP.titleFor = map .. "\n" .. title
		local n = map:match("^sgm_skate(%d+)_")
		local game = n and ("Skate " .. n .. ": ") or ""
		MAP.title = title ~= "" and (game .. title) or "Map"
	end
	return MAP.title
end

function MAP.Paint(w, h)
	if not MAP.Active() then return end
	PAD.Fonts()
	local district = MAP.DistrictTitle()
	PAD.Text(district and (MAP.Title() .. " - " .. district) or MAP.Title(), "skategm_ui_title", w / 2, h * 0.03, WHITE, TEXT_ALIGN_CENTER)
	local sub = MAP.target and "A: go to the dot" or "no floor under the dot"
	if not MAP.CanTeleport() then sub = "you're in a minigame: look, but no teleporting" end
	PAD.Text(sub, "skategm_ui_sub", w / 2, h * 0.075, MAP.target and WHITE or RED, TEXT_ALIGN_CENTER)
	-- names over the other skaters
	local a = PAD.API()
	for _, ply in ipairs(a and a.Skaters and a.Skaters() or {}) do
		local P = a.PoseOf and a.PoseOf(ply)
		if P and P.HIPS then
			local s = (P.HIPS + Vector(0, 0, 40)):ToScreen()
			if s.visible then PAD.Text(ply:Nick(), "skategm_ui_sub", s.x, s.y + 10, Color(255, 200, 70), TEXT_ALIGN_CENTER) end
		end
	end
	-- the dot itself, in the middle
	draw.RoundedBox(7, w / 2 - 7, h / 2 - 7, 14, 14, Color(CYAN.r, CYAN.g, CYAN.b, 220))
	draw.RoundedBox(3, w / 2 - 3, h / 2 - 3, 6, 6, WHITE)
	local ST = SkateGM and SkateGM.stream
	if ST and ST.on and ST.FocusReady and not ST.FocusReady() then
		local d = MAP.DistrictTitle()
		if SkateGM.PaintWait then
			SkateGM.PaintWait(w, h, RealTime(), MAP.loadingSince or RealTime(), d and ("Loading " .. d) or "Loading", nil, true)
		else
			PAD.Text("Loading...", "skategm_ui_title", w / 2, h / 2, WHITE, TEXT_ALIGN_CENTER)
		end
	end
	if MAP.note and RealTime() - MAP.note.t < 2 then PAD.Text(MAP.note.text, "skategm_ui_row", w / 2, h / 2 + 20, RED, TEXT_ALIGN_CENTER) end
	PAD.Legend(MAP.Legend(), w, h, "bottom")
end

if hook and hook.Add then
	hook.Add("HUDPaint", "skategm_ui_map", function() MAP.Paint(ScrW(), ScrH()) end)
	hook.Add("PostDrawTranslucentRenderables", "skategm_ui_map", function(depth, sky) if not (depth or sky) then MAP.DrawWorld() end end)
	-- (no HUD clutter over the map)
	hook.Add("HUDShouldDraw", "skategm_ui_map", function(name) if MAP.Active() and name ~= "CHudGMod" and name ~= "CHudChat" then return false end end)
end
