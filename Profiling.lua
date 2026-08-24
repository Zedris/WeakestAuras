-- WeakestAuras -- opt-in runtime profiler behind /wa prof: per-site wall time
-- and a session allocation-churn rate. Mirrors the idea of WA2's Profiling.lua,
-- scaled to a handful of measured sites.
--
-- Costs nothing until started: the inline WA.ProfBegin/ProfEnd hooks are one
-- flag test each, and the dispatch wrappers (ScanEvents, UpdatedTriggerState,
-- safecall) are only installed while running. Nothing here persists -- a reload
-- always comes back with profiling off.

if WeakestAuras.disabled then return end

local WA = WeakestAuras

WA.Profiling = {}
local P = WA.Profiling

-- Millisecond clock. debugprofilestop advances within a frame; GetTime advances
-- once per frame, so the fallback can only resolve costs that span frames and
-- the report names which clock it is on.
local hiRes = type(debugprofilestop) == "function"
local clock
if hiRes then
	clock = debugprofilestop
else
	clock = function() return GetTime() * 1000 end
end

local active = false
local stats = {} -- key -> { n, total, max, depth, start }
local startedAt = nil -- GetTime() of the current run, nil while stopped
local runSeconds = 0 -- accumulated across earlier start/stop spans
local churnKB, lastMem = 0, nil
local memTicker

local function out(msg)
	if WA.Debug and WA.Debug.Log then
		WA.Debug.Log(msg)
	else
		DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99WeakestAuras|r " .. msg)
	end
end

local function stat(key)
	local s = stats[key]
	if not s then
		s = { n = 0, total = 0, max = 0, depth = 0, start = 0 }
		stats[key] = s
	end
	return s
end

-- The two inline hooks. The depth counter makes a re-entrant site accrue once,
-- from the outermost pair.
function WA.ProfBegin(key)
	if not active then return end
	local s = stat(key)
	if s.depth == 0 then s.start = clock() end
	s.depth = s.depth + 1
end

function WA.ProfEnd(key)
	if not active then return end
	local s = stats[key]
	if not s or s.depth == 0 then return end
	s.depth = s.depth - 1
	if s.depth == 0 then
		local elapsed = clock() - s.start
		s.n = s.n + 1
		s.total = s.total + elapsed
		if elapsed > s.max then s.max = elapsed end
	end
end

-- Prefix-cached keys so the wrappers do not themselves allocate a string per
-- call -- that garbage would show up in the very churn number being measured.
local eventKeys, displayKeys, callKeys = {}, {}, {}
local function cachedKey(cache, prefix, name)
	local key = cache[name]
	if not key then
		key = prefix .. tostring(name)
		cache[name] = key
	end
	return key
end

-- Allocation churn: gcinfo() sampled once a second; only upward movement is
-- summed, so a collection pass resets the baseline without going negative.
-- KB resolution -- a rate, not a per-site attribution.
local function memTick()
	if type(gcinfo) ~= "function" then return end
	local m = gcinfo()
	if lastMem and m > lastMem then churnKB = churnKB + (m - lastMem) end
	lastMem = m
end

-- Dispatch wrappers, installed at Start and removed at Stop. Keys nest: an
-- event's time includes the displays it re-combined and the user code it ran.
local origScanEvents, origUpdatedTriggerState, origSafecall

local function install()
	origScanEvents = WA.ScanEvents
	WA.ScanEvents = function(event, a1, a2, a3, a4, a5, a6, a7, a8, a9)
		local key = cachedKey(eventKeys, "event: ", event)
		WA.ProfBegin(key)
		origScanEvents(event, a1, a2, a3, a4, a5, a6, a7, a8, a9)
		WA.ProfEnd(key)
	end
	origUpdatedTriggerState = WA.UpdatedTriggerState
	WA.UpdatedTriggerState = function(id)
		local key = cachedKey(displayKeys, "display: ", id)
		WA.ProfBegin(key)
		origUpdatedTriggerState(id)
		WA.ProfEnd(key)
	end
	origSafecall = WA.safecall
	WA.safecall = function(errTag, fn, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11)
		local key = cachedKey(callKeys, "call: ", errTag)
		WA.ProfBegin(key)
		local ok, res = origSafecall(errTag, fn, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11)
		WA.ProfEnd(key)
		return ok, res
	end
end

local function uninstall()
	if origScanEvents then WA.ScanEvents = origScanEvents; origScanEvents = nil end
	if origUpdatedTriggerState then
		WA.UpdatedTriggerState = origUpdatedTriggerState
		origUpdatedTriggerState = nil
	end
	if origSafecall then WA.safecall = origSafecall; origSafecall = nil end
end

function P.Start()
	if active then out("[prof] already running") return end
	active = true
	startedAt = GetTime()
	lastMem = nil
	memTick()
	if C_Timer and C_Timer.NewTicker then memTicker = C_Timer.NewTicker(1, memTick) end
	install()
	out("[prof] started (clock: " .. (hiRes and "debugprofilestop" or "GetTime, frame resolution") .. ")")
end

function P.Stop()
	if not active then out("[prof] not running") return end
	active = false
	uninstall()
	if memTicker then memTicker:Cancel(); memTicker = nil end
	memTick()
	runSeconds = runSeconds + (GetTime() - startedAt)
	startedAt = nil
	out("[prof] stopped; /wa prof report to see results, /wa prof reset to clear")
end

function P.Reset()
	stats = {}
	churnKB, lastMem = 0, nil
	runSeconds = 0
	if active then startedAt = GetTime(); memTick() end
	out("[prof] counters reset")
end

function P.Report(limit)
	limit = tonumber(limit) or 20
	local elapsed = runSeconds
	if active and startedAt then elapsed = elapsed + (GetTime() - startedAt) end
	if elapsed <= 0 then
		out("[prof] nothing recorded; /wa prof start, play a while, then /wa prof report")
		return
	end
	local minutes = elapsed / 60

	local rows = {}
	for key, s in pairs(stats) do
		if s.n > 0 then table.insert(rows, { key = key, s = s }) end
	end
	table.sort(rows, function(a, b) return a.s.total > b.s.total end)

	out(string.format("[prof] %s%.0fs profiled, clock %s, churn %.0f KB (%.0f KB/min)",
		active and "running, " or "", elapsed,
		hiRes and "debugprofilestop" or "GetTime (frame resolution)",
		churnKB, minutes > 0 and churnKB / minutes or 0))
	out("[prof] keys nest: an event's time includes the displays and code it drove")
	out("[prof]   total ms |  ms/min |  calls |  max ms | site")
	local n = table.getn(rows)
	if n > limit then n = limit end
	for i = 1, n do
		local s = rows[i].s
		out(string.format("[prof] %10.1f | %7.1f | %6d | %7.2f | %s",
			s.total, s.total / minutes, s.n, s.max, rows[i].key))
	end
	if table.getn(rows) > n then
		out("[prof] ... " .. (table.getn(rows) - n) .. " more; /wa prof report " .. table.getn(rows))
	end
end

function P.Command(rest)
	local _, _, sub, arg = string.find(rest or "", "^(%S*)%s*(.-)$")
	sub = string.lower(sub or "")
	if sub == "start" or sub == "on" then
		P.Start()
	elseif sub == "stop" or sub == "off" then
		P.Stop()
	elseif sub == "reset" then
		P.Reset()
	elseif sub == "report" or sub == "" then
		P.Report(arg)
	else
		out("[prof] usage: /wa prof start | stop | report [n] | reset")
	end
end

-- Read-only accessor for the harness.
function P.IsActive()
	return active
end
