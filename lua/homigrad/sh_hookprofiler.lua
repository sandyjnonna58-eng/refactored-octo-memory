-- Замер хуков: на несколько секунд оборачивает каждый хук таймером и печатает самые тяжёлые.
-- rem_profile [секунды]     - у себя (клиент), по умолчанию 10 с
-- rem_profile_sv [секунды]  - на сервере (только суперадмин), результат приходит в консоль вызвавшему
-- Столбцы: всего мс за замер, мс на вызов, вызовов, мс за кадр/тик в среднем, событие и имя хука.
hg.HookProfiler = hg.HookProfiler or {}
local HP = hg.HookProfiler

local SysTime = SysTime
local TOP = 30

local function Report(stats, seconds, frames, out)
	local rows = {}
	for key, s in pairs(stats) do
		rows[#rows + 1] = {key = key, total = s.total, calls = s.calls}
	end
	table.sort(rows, function(a, b) return a.total > b.total end)

	local sum = 0
	for _, r in ipairs(rows) do sum = sum + r.total end

	out(string.format("==== hook profile: %.1f s, %d frames, all hooks %.2f ms/frame ====", seconds, frames, sum * 1000 / math.max(frames, 1)))
	out(string.format("%10s %10s %8s %10s  %s", "total ms", "ms/call", "calls", "ms/frame", "hook"))
	for i = 1, math.min(TOP, #rows) do
		local r = rows[i]
		out(string.format("%10.2f %10.4f %8d %10.4f  %s", r.total * 1000, r.total * 1000 / math.max(r.calls, 1), r.calls, r.total * 1000 / math.max(frames, 1), r.key))
	end
end

function HP.Run(seconds, out, done)
	if HP.Running then out("profiler is already running") return end
	HP.Running = true

	local stats = {}
	local wrapped = {}

	for event, hooks in pairs(hook.GetTable()) do
		for name, func in pairs(hooks) do
			if isfunction(func) then
				local key = event .. "  /  " .. tostring(name)
				local s = {total = 0, calls = 0}
				stats[key] = s
				local wrapper = function(...)
					local st = SysTime()
					local a, b, c, d, e, f = func(...)
					s.total = s.total + (SysTime() - st)
					s.calls = s.calls + 1
					return a, b, c, d, e, f
				end
				wrapped[#wrapped + 1] = {event, name, func, wrapper}
				hook.Add(event, name, wrapper)
			end
		end
	end

	local frames = 0
	local counterEvent = SERVER and "Tick" or "Think"
	local counterName = "rem_hookprofiler_frames"
	hook.Add(counterEvent, counterName, function() frames = frames + 1 end)

	local started = SysTime()
	out(string.format("profiling %d hooks for %d s...", #wrapped, seconds))

	timer.Simple(seconds, function()
		hook.Remove(counterEvent, counterName)
		-- возвращаем оригиналы, если хук за это время не заменили и не убрали
		for _, w in ipairs(wrapped) do
			local event, name, func, wrapper = w[1], w[2], w[3], w[4]
			local cur = hook.GetTable()[event]
			if cur and cur[name] == wrapper then
				hook.Add(event, name, func)
			end
		end
		stats[counterEvent .. "  /  " .. counterName] = nil
		Report(stats, SysTime() - started, frames, out)
		HP.Running = false
		if done then done() end
	end)
end

if CLIENT then
	concommand.Add("rem_profile", function(_, _, args)
		HP.Run(math.Clamp(tonumber(args[1]) or 10, 1, 120), print)
	end)
end

if SERVER then
	concommand.Add("rem_profile_sv", function(ply, _, args)
		if IsValid(ply) and not ply:IsSuperAdmin() then return end
		local out = function(text)
			print(text)
			if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, text) end
		end
		HP.Run(math.Clamp(tonumber(args[1]) or 10, 1, 120), out)
	end)
end
