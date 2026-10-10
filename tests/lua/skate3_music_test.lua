dofile("gmock.lua")
local cv = { skategm_skate3_music = "1", skategm_skate3_music_volume = "0.5" }
function CreateClientConVar(n, d)
	return { GetBool = function() return (cv[n] or d) ~= "0" end, GetFloat = function() return tonumber(cv[n] or d) end }
end
GMOD_CHANNEL_STOPPED, GMOD_CHANNEL_PLAYING, GMOD_CHANNEL_PAUSED = 0, 1, 2
local channels = {}
local function Channel(path, flags)
	local ch = { path = path, flags = flags, t = 0, vol = 1, state = 0, seeks = {} }
	function ch:IsValid() return not self.gone end
	function ch:SetVolume(v) self.vol = v end
	function ch:Play() self.state = 1 end
	function ch:Pause() self.state = 2 end
	function ch:Stop() self.state = 0 self.gone = true end
	function ch:GetTime() return self.t end
	function ch:SetTime(t) self.t = t self.seeks[#self.seeks + 1] = t end
	function ch:GetState() return self.state end
	return ch
end
sound = { PlayFile = function(path, flags, cb) local ch = Channel(path, flags) channels[#channels + 1] = ch cb(ch) end }
function IsValid(x) return x ~= nil and (type(x) ~= "table" or not x.IsValid or x:IsValid()) end
local manifest
local songs = {
	{ id = "a_one", file = "sound/skate3/music/a_one.ogg", artist = "Artist A", title = "One", seconds = 100 },
	{ id = "b_two", file = "sound/skate3/music/b_two.ogg", artist = "Artist B", title = "Two", seconds = 120 },
	{ id = "c_three", file = "sound/skate3/music/c_three.ogg", artist = "Artist C", title = "Three", seconds = 90 },
}
file = { Read = function(p, where) return p == "skategm/skate3_music.json" and where == "DATA" and manifest or nil end, Exists = function(p, where) return where == "GAME" and p:find("^sound/skate3/music/") ~= nil end }
util = { JSONToTable = function(t) return t == "manifest" and { version = 1, songs = songs } or nil end }
local netUsed = false
net = setmetatable({}, { __index = function() netUsed = true return function() end end })
local hooks = {}
hook = { Add = function(ev, id, f) hooks[ev .. "/" .. id] = f end }
local real = 0
function RealTime() return real end
local pad = { buttons = 0, rx = 0, ry = 0 }
SkateGM = { API = { Pad = function() return pad end }, phase = "on" }
local S = SkateGM
local cmds = {}
function RunConsoleCommand(n, v) cmds[#cmds + 1] = { n, v } cv[n] = v end
dofile("../../addon/skategm/lua/skategm/cl_skate3_music.lua")
local SM = S.skate3Music
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local LB, RS = 0x0100, 0x0080

SM.Think(0, 0, 0)
check("no songs installed: no music, though it's on", not SM.Have() and not SM.On() and #channels == 0)
manifest = "manifest"
SM.songs = nil
check("on by default once the installer has put the songs in", SM.cvOn:GetBool() and SM.Have() and #SM.Songs() == 3)
math.randomseed(3)
SM.Think(1, 1, 0.016)
local first = SM.me.id
local ch = channels[1]
check("skating: a shuffled song from the start, at the music volume", ch and ch.path == SM.byId[first].file and ch.flags == "noplay noblock" and ch.state == GMOD_CHANNEL_PLAYING and math.abs(ch.vol - 0.5) < 1e-6)
check("... its name slides in", SM.note.text == "Artist " .. first:sub(1, 1):upper() .. " - " .. SM.byId[first].title)
check("nothing sent to the server: no one else hears it", not netUsed)
ch.t = 10
S.phase = "off"
SM.Think(11, 11, 0.016)
check("not skating: paused where it was", SM.me.paused and math.abs(SM.me.paused - 10) < 1e-6 and ch.state == GMOD_CHANNEL_PAUSED)
SM.Think(100, 100, 0.016)
S.phase = "loading"
SM.Think(100.5, 100.5, 0.016)
check("loading Skater mode: the music already plays", SM.me.paused == nil and ch.state == GMOD_CHANNEL_PLAYING)
S.phase = "off"
SM.Think(100.6, 100.6, 0.016)
S.phase = "on"
SM.Think(101, 101, 0.016)
check("skating again: on from the same moment", SM.me.paused == nil and math.abs(SM.Time(SM.me, 101) - 10.1) < 1e-6 and ch.state == GMOD_CHANNEL_PLAYING)
SKATEGM_UI = { IsOpen = function(name) return name == "replay" end }
SM.Think(101.5, 101.5, 0.016)
check("the replay editor open: paused", SM.me.paused and ch.state == GMOD_CHANNEL_PAUSED)
SKATEGM_UI = nil
SM.Think(101.6, 101.6, 0.016)
check("... closed: plays on from there", SM.me.paused == nil and math.abs(SM.Time(SM.me, 101.6) - 10.6) < 1e-6 and ch.state == GMOD_CHANNEL_PLAYING)
pad.buttons = RS
SM.Think(102, 102, 0.016)
check("right stick click without LB: left alone (rocket, tricks)", SM.me.paused == nil)
pad.buttons = LB
SM.Think(102.1, 102.1, 0.016)
pad.buttons = LB + RS
SM.Think(102.2, 102.2, 0.016)
check("LB + right stick click: paused", SM.me.paused and ch.state == GMOD_CHANNEL_PAUSED and SM.note.text == "Music paused")
SM.Think(102.3, 102.3, 0.016)
pad.buttons = LB
SM.Think(150, 150, 0.016)
check("... stays paused while skating", SM.me.paused ~= nil and math.abs(SM.me.paused - 11.2) < 1e-6)
pad.buttons = LB + RS
SM.Think(151, 151, 0.016)
check("click again: plays on", SM.me.paused == nil and math.abs(SM.Time(SM.me, 151) - 11.2) < 1e-6)
pad.buttons = LB
pad.rx = 0.9
SM.Think(152, 152, 0.016)
local second = SM.me.id
check("LB + right stick right: the next song", second == SM.order[2] and second ~= first and ch.gone)
ch = channels[#channels]
SM.Think(152.1, 152.1, 0.016)
check("... held over: one skip", SM.me.id == second)
pad.rx = 0
SM.Think(160, 160, 0.016)
pad.rx = -0.9
SM.Think(170, 170, 0.016)
check("LB + right stick left: from the start", SM.me.id == second and SM.Time(SM.me, 170) == 0)
pad.rx, pad.ry = 0, 1
for i = 1, 30 do SM.Think(170 + i * 0.016, 170 + i * 0.016, 0.016) end
check("LB + right stick up: louder", SM.Volume() > 0.7 and math.abs(ch.vol - SM.Volume()) < 1e-6 and SM.note.volume == true)
check("... the volume box stays out while it's changed (no sliding in again)", real - SM.note.t <= SM.SLIDE + 1e-6 or SM.Slide(170.48 - SM.note.t) == 1)
pad.ry = 0
SM.Think(172, 172, 0.016)
check("... let go: saved", cmds[#cmds][1] == "skategm_skate3_music_volume" and tonumber(cmds[#cmds][2]) > 0.7 and SM.volume == nil)
cv.skategm_skate3_music_volume = "0.5"
pad.buttons = 0
SKATEGM_MODES = { music = { current = { vol = 0.6 } } }
SM.Think(173, 173, 0.016)
check("a minigame's own music playing: ours goes quiet", ch.gone)
SKATEGM_MODES = nil
SM.Think(174, 174, 0.016)
check("... back after it, at the right moment", channels[#channels].state == GMOD_CHANNEL_PLAYING and math.abs(channels[#channels].t - 4) < 1e-6)
SM.Think(175 + SM.byId[second].seconds, 175 + SM.byId[second].seconds, 0.016)
check("the song ends: the next one", SM.me.id == SM.order[3])
local stick = {}
skategm = { SetLBRightStick = function(on) stick[#stick + 1] = on end }
SM.stickSent = nil
SM.Think(400, 400, 0.016)
SM.Think(401, 401, 0.016)
check("the module keeps the right stick from the skater with LB held (told once)", #stick == 1 and stick[1] == 1)
local words, polys = {}, 0
draw = { RoundedBox = function() end, SimpleText = function(t) words[#words + 1] = t end, NoTexture = function() end }
surface = { SetFont = function() end, GetTextSize = function(t) return #t * 10, 20 end, SetDrawColor = function() end, DrawPoly = function() polys = polys + 1 end }
local at = {}
local function text(t, font, x, y, col, ax, ay) at[t] = { x = x, y = y, ax = ax, ay = ay } end
local shown = SM.PaintControls(1920, 1080, 19, Color(120, 220, 255), text, false)
local up, down, left, right = at["volume up"], at["volume down"], at["start over"], at["skip"]
check("LB held: a right stick drawn like the D-pad, its four ways labelled", shown and polys == 4 and up and down and left and right
	and up.y < down.y and left.x < right.x and left.ax == TEXT_ALIGN_RIGHT and right.ax == TEXT_ALIGN_LEFT)
check("... bottom left, where the trick display is, all on screen", left.x - 100 >= 0 and right.x < 1920 / 2 and up.y > 1080 / 2)
check("... and what a click does", at["click: pause"] ~= nil)
at = {}
SM.PaintControls(1920, 1080, 19, Color(120, 220, 255), text, true)
check("... on the keyboard: Ctrl instead of a click", at["Ctrl: pause"] ~= nil and words[#words] == "Ctrl")
check("the name slides in, holds, slides out", SM.Slide(0) == 0 and SM.Slide(SM.SLIDE / 2) > 0 and SM.Slide(SM.SLIDE / 2) < 1 and SM.Slide(2) == 1
	and SM.Slide(SM.NOTE_TIME - SM.SLIDE / 2) < 1 and SM.Slide(SM.NOTE_TIME) == 0)
local boxes = {}
draw = { RoundedBox = function(r, x, y, w, h, col) boxes[#boxes + 1] = { x = x, w = w, col = col } end, SimpleText = function() end }
surface = { SetFont = function() end, GetTextSize = function(t) return #t * 10, 20 end }
SM.note = { text = "Artist - Song", t = 0 }
SM.Paint(1920, 1080, 2)
local held = boxes[1]
SM.Paint(1920, 1080, 0.05)
check("... on a dark see-through box like the menus, coming from the right", held and held.col.a > 0 and held.col.a < 255 and held.x + held.w < 1920 and boxes[2].x > held.x)
boxes = {}
local texts = {}
draw.SimpleText = function(tx, f, x) texts[#texts + 1] = tx end
SM.volume = 0.25
SM.note = { text = "Music volume", volume = true, t = 0 }
SM.Paint(1920, 1080, 2)
SM.volume = nil
local bar, full, dot = boxes[2], boxes[3], boxes[4]
check("changing the volume: a slider, top right, on the same box", #boxes == 4 and boxes[1].col.a < 255 and texts[1] == "Music volume" and texts[2] == "25%")
check("... darker blue up to the dot, lighter blue for the rest", full.w == math.floor(bar.w * 0.25 + 0.5) and full.col.b > full.col.r and bar.col.r > full.col.r and bar.col.g > full.col.g
	and math.abs(dot.x + dot.w / 2 - (bar.x + full.w)) < 1e-6)
local mine = SM.mine.ch
cv.skategm_skate3_music = "0"
SM.Think(402, 402, 0.016)
check("Music off: it stops; LB still keeps the right stick from the skater", mine.gone and SM.me == nil and stick[#stick] == 1)
check("the hooks are in", hooks["Think/skategm_skate3_music"] and hooks["HUDPaint/skategm_skate3_music"])
