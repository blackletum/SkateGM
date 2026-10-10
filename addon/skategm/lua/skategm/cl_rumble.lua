local S = SkateGM

local RU = S.rumble or {}
S.rumble = RU
RU.pulses = RU.pulses or {}
RU.SEND_GAP = 1 / 30
RU.HOLD = 0.25
RU.CHANGE = 0.03
RU.ROLLING = { ground = true, slide = true, metalgrind = true, woodgrind = true }
RU.GRIND = { metalgrind = true, woodgrind = true }

RU.cvOn = RU.cvOn or CreateClientConVar("skategm_rumble", "1", true, false, "1 = the controller rumbles (landings, pops, grinds, bails, the rocket)", 0, 1)
RU.cvStrength = RU.cvStrength or CreateClientConVar("skategm_rumble_strength", "1", true, false, "Rumble strength, 0-1", 0, 1)

function RU.Pulse(low, high, seconds, now)
	RU.pulses[#RU.pulses + 1] = { low = low, high = high, from = now, to = now + seconds }
end

function RU.Events(A, prev, cat, now)
	if not prev or prev == cat then return end
	if RU.ROLLING[prev] and cat == "air" and (A.vz or 0) > 40 then
		RU.Pulse(0.1, 0.35, 0.08, now)
	end
	if prev == "air" and RU.GRIND[cat] then
		RU.Pulse(0.3, 0.5, 0.12, now)
	elseif prev == "air" and RU.ROLLING[cat] then
		local impact = -(A.minVz or 0)
		if impact > 80 then
			local k = math.Clamp(impact / 600, 0.2, 1)
			RU.Pulse(k, 0.6 * k, 0.1 + 0.15 * k, now)
		end
	elseif RU.GRIND[cat] and not RU.GRIND[prev] then
		RU.Pulse(0.2, 0.4, 0.1, now)
	end
	if cat == "wipeout" then
		RU.Pulse(0.9, 0.7, 0.35, now)
	end
	if prev == "walkair" and cat == "walk" then
		RU.Pulse(0.15, 0.1, 0.08, now)
	end
end

function RU.Steady(cat, speed)
	local low, high = 0, 0
	if RU.GRIND[cat] then
		low, high = 0.05, math.Clamp(0.12 + (speed or 0) / 4000, 0.12, 0.3)
	end
	if S.rocketOn then
		low, high = math.max(low, 0.2), math.max(high, 0.08)
	end
	return low, high
end

function RU.Level(now)
	local low, high = RU.Steady(RU.cat, RU.speed)
	for i = #RU.pulses, 1, -1 do
		local p = RU.pulses[i]
		if now >= p.to then
			table.remove(RU.pulses, i)
		else
			local k = 1 - (now - p.from) / (p.to - p.from)
			low, high = math.max(low, p.low * k), math.max(high, p.high * k)
		end
	end
	local s = RU.cvOn:GetBool() and math.Clamp(RU.cvStrength:GetFloat(), 0, 1) or 0
	return low * s, high * s
end

function RU.Send(low, high, seconds)
	if skategm and skategm.Rumble then skategm.Rumble(low, high, seconds) end
end

function RU.Think(now)
	local live = S.phase == "on" and not S.frozen and not (gui and gui.IsGameUIVisible and gui.IsGameUIVisible())
	if not live then
		RU.pulses, RU.cat = {}, nil
	end
	local low, high = 0, 0
	if live then low, high = RU.Level(now) end
	local was = RU.sent
	local on = low > 0.005 or high > 0.005
	if not on then
		if was then
			RU.sent = nil
			RU.Send(0, 0, 0)
		end
		return
	end
	if was and math.abs(was.low - low) < RU.CHANGE and math.abs(was.high - high) < RU.CHANGE and now - was.t < RU.HOLD * 0.5 then return end
	if was and now - was.t < RU.SEND_GAP then return end
	RU.sent = { low = low, high = high, t = now }
	RU.Send(low, high, RU.HOLD)
end

function S.RumbleEvents(A, prev, cat, now)
	RU.cat, RU.speed = cat, A.speed
	RU.Events(A, prev, cat, now)
end

hook.Add("Think", "skategm_rumble", function() pcall(RU.Think, RealTime()) end)
hook.Add("ShutDown", "skategm_rumble", function() RU.Send(0, 0, 0) end)
