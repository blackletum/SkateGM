-- Rocket Royale, server: the game. Uses only SkateGM.API from the skating add-on.
if not SKATEGM_MODES.Game then include("skategm_modes/sv_game.lua") end

local RR = ROCKETROYALE
local G, S

local function Riding()
	local out = {}
	for _, p in ipairs(S.players or {}) do
		local e = G.Entry(p)
		if e and e.playing and not e.out then out[#out + 1] = p end
	end
	return out
end

G = SKATEGM_MODES.Game(RR, {
	freeze = false,
	minPlayers = 2,
	resetEntry = function(e) e.playing, e.out, e.slot, e.lasted = nil, nil, nil, nil end,
	publicPlayer = function(p, e) return { playing = e.playing or nil, out = e.out or nil, slot = e.slot, lasted = e.lasted } end,
	public = function(S, t)
		t.start = { S.start.x, S.start.y, S.start.z }
		t.yaw, t.time = S.yaw, S.time
		t.winners = S.winners
		t.slots = S.slots
	end,
	create = function(S, ply, m)
		S.start, S.yaw = SKATEGM_MODES.HostStart(ply, m)
		S.time = RR.ClampTime(m.time)
		S._boardRules = SKATEGM_MODES.CleanRules({ rocket = "force", hover = type(m.rules) == "table" and m.rules.hover })
	end,
	begin = function(S, now)
		S.slots = #S.players
		for i, p in ipairs(S.players) do
			local e = G.Entry(p)
			e.playing, e.out, e.slot, e.lasted, e.offSince = true, nil, i, nil, nil
		end
		S.phase, S.deadline = "countdown", now + RR.COUNTDOWN
		G.Broadcast(now)
	end,
	lobby = function(S) S.winners, S.startedAt = nil, nil end,
	results = function(S, now, why)
		local riding = Riding()
		S.winners = {}
		for _, p in ipairs(riding) do S.winners[#S.winners + 1] = p:Nick() end
		if #riding == 1 then return riding[1]:Nick() .. " wins Rocket Royale!" end
		if #riding > 1 then return (why or "time's up") .. ": " .. table.concat(S.winners, ", ") .. " rode it out" end
		return "nobody's left"
	end,
	removed = function(S, ply, now)
		if (S.phase == "playing" or S.phase == "countdown") and #Riding() <= 1 then G.Results(now) return true end
	end,
	offSkate = {
		during = { "playing" }, seconds = RR.OFF_GRACE,
		skip = function(S, p, e) return not e.playing or e.out end,
		action = function(S, p, now) RR.Out(p, now, "left Skater mode") end,
	},
	tick = {
		countdown = function(S, now)
			if now > S.deadline then
				S.phase, S.deadline, S.startedAt = "playing", now + S.time, now
				G.Broadcast(now)
			end
		end,
		playing = function(S, now) if now > S.deadline then G.Results(now) end end,
	},
	handlers = {
		bailed = function(ply, m, now) RR.Out(ply, now, "bailed") end,
	},
})
S = G.S

function RR.Out(ply, now, why)
	local e = G.IndexOf(ply) and G.Entry(ply)
	if S.phase ~= "playing" or not e or not e.playing or e.out then return end
	e.out, e.lasted = true, math.floor((now - (S.startedAt or now)) * 10) / 10
	G.TellGame(string.format("%s %s after %.1f s", ply:Nick(), why or "bailed", e.lasted))
	if #Riding() <= 1 then return G.Results(now) end
	G.Broadcast(now)
end
