dofile("gmock.lua")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end

local frame = Vector(0, 0, 0)
local ME = { GetNW2Vector = function() return frame end, GetPos = function() return Vector(0, 0, 0) end }
function LocalPlayer() return ME end
function IsValid(x) return x ~= nil end
function RealTime() return 0 end
function SysTime() return os.clock() end
game = { GetMap = function() return "sgm_skate3_portcarverton" end }
SkateGM = {}
local S = SkateGM

local INDEX = {
	tile = 5040, cell = 8192, skyname = "city_university", atlases = { "lm/a0" },
	materials = { { name = "m0", kind = 0 }, { name = "m1", kind = 3 } },
	districts = {
		{ id = "DIST_University", title = "University", spawn = { 10, 20, 30 }, lo = { -40000, -40000 }, hi = { 40000, 40000 },
			sea = { z = -2400, colour = { 1, 2, 3 } }, ground = "g_uni.bin", sky = "city_university" },
		{ id = "DIST_DownTown", title = "Downtown", spawn = { 270000, 0, 1000 }, lo = { 230000, -40000 }, hi = { 310000, 40000 }, sky = "city_downtown" },
	},
	tiles = {
		["0 0"] = { ["0"] = { file = "t0_0_0.bin", tris = 10, lo = { 0, 0, 0 }, hi = { 5040, 5040, 100 }, mats = { 0 }, atl = { 0 } },
			["1"] = { file = "t0_0_1.bin", tris = 2, lo = { 0, 0, 0 }, hi = { 5040, 5040, 100 } } },
		["5 0"] = { ["0"] = { file = "t5_0_0.bin", tris = 10, lo = { 25200, 0, 0 }, hi = { 30240, 5040, 100 } } },
		["-1 2"] = { ["1"] = { file = "t-1_2_1.bin", tris = 3, lo = { -5040, 10080, 0 }, hi = { 0, 15120, 50 } } },
	},
}

-- a ground grid: 2 x 2 cells of 96, two levels; cell (1, 0) has floors at 100 and 600
local function GridFile()
	local shorts = { 32767, 32767, 50, 300, 32767, 32767, 32767, 32767 }
	local f = { at = 0, pos = 4, header = { 0, 0, 96 }, longs = { 2, 2, 2 } }
	local fi, li = 0, 0
	function f:Read(n) return "SGG1" end
	function f:ReadFloat() fi = fi + 1 return self.header[fi] end
	function f:ReadULong() li = li + 1 return self.longs[li] end
	function f:Seek(p) self.at = p end
	function f:ReadShort()
		local i = (self.at - 28) / 2 + 1
		self.at = self.at + 2
		return shorts[i]
	end
	function f:Close() end
	return f
end

file = {
	Read = function(path) if path:find("index.json", 1, true) then return "json" end end,
	Open = function(path) if path:find("g_uni.bin", 1, true) then return GridFile() end end,
}
util.JSONToTable = function() return INDEX end
local shifted
S.FrameShifted = function(d) shifted = d end

dofile("../../addon/skategm/lua/skategm/cl_stream.lua")
local ST = S.stream
ST.Setup()
check("a streamed map is found by its index", ST.on and ST.map == "sgm_skate3_portcarverton")
check("its tiles, with their levels of detail (keys as JSON gives them)", ST.tiles["0 0"] and ST.tiles["0 0"].info[0] and ST.tiles["0 0"].info[1] and ST.tiles["-1 2"].info[1] and not ST.tiles["-1 2"].info[0])
check("the frame offset and far clip are taken over", S.frameOffset == ST.Frame and S.viewZFar == ST.ZFAR and S.WaterLevel == ST.WaterLevel)

local i, d = ST.DistrictAt(Vector(1000, 0, 0))
check("University holds the middle", d and d.title == "University")
i, d = ST.DistrictAt(Vector(265000, 5000, 0))
check("Downtown holds its own area", d and d.title == "Downtown")
i, d = ST.DistrictAt(Vector(150000, 0, 0))
check("between them, the nearer one", d and d.title == "Downtown")

check("the sea level, in Lua's frame", ST.WaterLevel(Vector(0, 0, 0)) == -2400)
frame = Vector(8192, 0, 0)
check("... the same in a shifted frame (z isn't shifted)", ST.WaterLevel(Vector(-8192, 0, 0)) == -2400)
check("a district without a sea has no water level", ST.WaterLevel(Vector(270000 - 8192, 0, 0)) == nil)
frame = Vector(0, 0, 0)

local fb = ST.FloorBelow(Vector(100, 10, 1000))
check("the floor under a point: the highest one below it", fb and fb.z == 600)
fb = ST.FloorBelow(Vector(100, 10, 300))
check("... below a lower cut, the lower floor", fb and fb.z == 100)
check("... none under a cell with no floors", ST.FloorBelow(Vector(10, 10, 1000)) == nil)
check("... none outside the grid", ST.FloorBelow(Vector(10000, 10, 1000)) == nil)


S.view = { origin = Vector(100, 100, 50) }
local want = ST.Want()
check("near tiles get their full detail first", want and want[1] == ST.tiles["0 0"] and want[2] == 0)
ST.tiles["0 0"].built[0] = { groups = {} }
want = ST.Want()
check("... then the far ones' low detail", want and want[2] == 1)
check("a tile too far for full detail isn't asked for it", ST.tiles["5 0"].dist > ST.NEAR)
check("the area is ready when no near tile is missing", ST.NearReady() == true)
ST.tiles["5 0"].dist = 1
check("... and not while one is", ST.NearReady() == false)

local freed = false
ST.tiles["5 0"].built[0] = { groups = { { meshes = { { Destroy = function() freed = true end } } } } }
S.view = { origin = Vector(-30000, 0, 0) }
ST.Want()
check("a tile just left behind keeps its full detail a moment (a one-frame jump frees nothing)", not freed and ST.tiles["5 0"].built[0] ~= nil)
ST.tiles["5 0"].leftAt = -10
ST.Want()
check("full detail is freed once a tile has been left behind a while", freed and ST.tiles["5 0"].built[0] == nil)

local travelled
S.API = { TeleportTo = function(p, yaw) travelled = p return true end }
frame = Vector(253952, 0, 0)
ST.Travel(2)
check("travel puts you on the district's spawn, in your frame", travelled and travelled.x == 270000 - 253952 and travelled.y == 0 and travelled.z == 1000)
frame = Vector(0, 0, 0)
check("two districts to choose from", #ST.Districts() == 2)

local clock = 100
function RealTime() return clock end
local ST2 = S.stream
frame = Vector(0, 0, 0)
S.view = { origin = Vector(6100, 0, 100) }
ST2.lastCam, ST2.arriveFrame, ST2.arrive, ST2.shiftedAt = nil, nil, nil, nil
ST2.ArriveThink()
ST2.arrive = nil
clock = clock + 0.016
S.view.origin = Vector(6120, 0, 100)
ST2.ArriveThink()
check("riding along: no arrival screen", ST2.arrive == nil)
frame = Vector(8192, 0, 0)
clock = clock + 0.016
ST2.ArriveThink()
check("crossing into the next cell (the view a frame behind): no black screen", ST2.arrive == nil)
S.view.origin = Vector(6140 - 8192, 0, 100)
clock = clock + 0.016
ST2.ArriveThink()
check("... nor once the view catches up", ST2.arrive == nil)
clock = clock + 1
S.view.origin = Vector(60000, 0, 100)
ST2.ArriveThink()
check("a camera cut (a flyover, spectating) doesn't black out", ST2.arrive == nil)
S.pose = { pos = { 6140, 0, 100 } }
ST2.ArriveThink()
clock = clock + 0.016
S.pose.pos = { 60000, 0, 100 }
ST2.ArriveThink()
check("the skater jumping far (a teleport) still fades to black", ST2.arrive ~= nil)
S.pose.pos = { 60010, 0, 100 }
clock = clock + 1
ST2.ArriveThink()
ST2.arrive = nil
frame = Vector(270336, 0, 0)
ST2.ArriveThink()
check("a teleport that also changes cell: held dark by the teleport itself", ST2.arrive == nil and (function() ST2.Arrive() return ST2.arrive ~= nil end)())
S.pose = nil
ST2.arrive, ST2.focusAt = nil, nil
clock = clock + 2
ST2.ArriveThink()
ST2.arrive = nil
ST2.SetFocus(Vector(270000, -20000, 1300))
clock = clock + 0.016
ST2.ArriveThink()
check("the map looking at another district: no black screen", ST2.arrive == nil and ST2.Camera().x == 270000)
ST2.SetFocus(nil)
clock = clock + 0.016
ST2.ArriveThink()
check("... nor when it lets go", ST2.arrive == nil)

local function T(ix, iy)
	return { ix = ix, iy = iy, info = { [0] = { tris = 1 } }, built = {}, centre = Vector(ix * 5040 + 2520, iy * 5040 + 2520, 0), origin = Vector(ix * 5040 + 2520, iy * 5040 + 2520, 0) }
end
local saved = ST2.tiles
ST2.tiles = { a = T(0, 0), ahead = T(1, 0), behind = T(-1, 0) }
ST2.focus, ST2.job, ST2.lead = nil, nil, nil
frame = Vector(0, 0, 0)
S.view = { origin = Vector(1000, 2520, 0) }
ST2.leadCam, ST2.leadVel = nil, nil
ST2.Lead(10)
S.view.origin = Vector(1030, 2520, 0)
ST2.Lead(10.016)
for _ = 1, 60 do S.view.origin = S.view.origin + Vector(30, 0, 0) ST2.Lead(10.016 + _ * 0.016) end
S.pose = { pos = { S.view.origin.x, S.view.origin.y, 0 } }
local w = ST2.Want()
check("loading: the tile you're on first, even at speed", w and w[1] == ST2.tiles.a)
ST2.tiles.a.built[0] = { groups = {} }
w = ST2.Want()
check("... then the one you're heading for, before the one behind", w and w[1] == ST2.tiles.ahead)
ST2.tiles.a.built[0] = nil
ST2.job = { tile = ST2.tiles.behind, lod = 0, co = coroutine.create(function() end) }
ST2.tiles.behind.jobs = { [0] = ST2.job }
ST2.paused = {}
local budget = ST2.BUDGET
ST2.BUDGET = -1
ST2.Think()
ST2.BUDGET = budget
check("a nearer tile interrupts one being built further away", ST2.job == nil and ST2.paused[ST2.tiles.behind.jobs[0]] == true)
local paused = ST2.tiles.behind.jobs[0]
ST2.Start(ST2.tiles.behind, 0)
check("... which picks up where it left off later", ST2.job == paused and ST2.paused[paused] == nil)
ST2.Free(ST2.tiles.behind, 0)
check("a tile freed while waiting cancels its build", paused.cancelled == true and ST2.tiles.behind.jobs[0] == nil)
ST2.tiles, ST2.job = saved, nil
S.pose = nil

local made
CreateMaterial = function(name, shader, kv) made = { name = name, shader = shader, kv = kv } return { SetFloat = function(self, k, v) self[k] = v end } end
local tex = setmetatable({ GetName = function() return "skategm/x/d_1" end }, { __index = function() end })
local fakeMat = { GetName = function() return "skategm/x/m1" end, GetShader = function() return "LightmappedGeneric_DX90" end,
	GetKeyValues = function() return { ["$basetexture"] = tex, ["$flags"] = 0, ["$alphatest"] = 1 } end }
type = (function(t) return function(v) if v == tex then return "ITexture" end return t(v) end end)(type)
local fm = ST2.FadeMaterial(fakeMat)
check("a fading tile draws through a see-through copy of its material", made and made.shader == "LightmappedGeneric" and made.kv["$translucent"] == 1 and made.kv["$basetexture"] == "skategm/x/d_1" and made.kv["$alphatest"] == nil and made.kv["$flags"] == nil)
check("... one copy per material", ST2.FadeMaterial(fakeMat) == fm)
clock = 500
check("a tile fades for half a second after it's built, then draws as usual", ST2.Fading({ born = 499.8 }, clock) and not ST2.Fading({ born = 499.4 }, clock) and not ST2.Fading({}, clock))
ST2.focus, ST2.stable = nil, {}
frame = Vector(0, 0, 0)
S.view = { origin = Vector(6100, 10, 0) }
ST2.Camera()
frame = Vector(8192, 0, 0)
local c1 = ST2.Camera()
check("streaming: on a cell crossing with the view a frame behind, you stay where you are", math.abs(c1.x - 6100) < 1)
S.view.origin = Vector(6120 - 8192, 10, 0)
local c2 = ST2.Camera()
check("... and follow on once it catches up", math.abs(c2.x - 6120) < 1)

ST2.stable = {}
frame = Vector(0, 0, 0)
ST2.renderOrigin, ST2.renderAt = Vector(40000, 0, 500), clock
S.view = { origin = Vector(100, 0, 0) }
check("what streams in follows the camera actually rendered (flyovers, spectating, free cams)", ST2.Camera().x == 40000)
ST2.renderAt = clock - 5
check("... falling back to the skater's camera when nothing was rendered lately", ST2.Camera().x == 100)
ST2.renderOrigin = nil
local function TT(ix) return { ix = ix, iy = 0, info = { [0] = { tris = 1 } }, built = {}, centre = Vector(ix * 5040 + 2520, 2520, 0), origin = Vector(ix * 5040 + 2520, 2520, 0) } end
local keep = ST2.tiles
ST2.tiles = { near_me = TT(0), near_cam = TT(10), between = TT(5) }
ST2.renderOrigin, ST2.renderAt = Vector(10 * 5040 + 2520, 2520, 0), clock
S.pose = { pos = { 2520, 2520, 0 } }
ST2.lead = nil
ST2.Want()
check("tiles around both the camera and the skater are kept (a far flyover doesn't drop where you'll land)", ST2.tiles.near_me.dist == 0 and ST2.tiles.near_cam.dist == 0 and ST2.tiles.between.dist == 5)
ST2.tiles, S.pose, ST2.renderOrigin = keep, nil, nil
frame = Vector(0, 0, 0)
local uni = ST.index.districts[1]
uni.water = "g_uni.bin"
ST.grids = {}
check("water from the map's own water surfaces: the one under you", ST.WaterLevel(Vector(150, 40, 150)) == 100)
check("... the upper one where two are stacked and you're above it", ST.WaterLevel(Vector(150, 40, 700)) == 600)
check("... the one over you when you're under water", ST.WaterLevel(Vector(150, 40, -300)) == 100)
check("... and the district's sea where there's no water surface", ST.WaterLevel(Vector(10, 10, 0)) == -2400)
uni.water = nil
ST.grids = {}
