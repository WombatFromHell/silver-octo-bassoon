-- tests/harness.lua — run session-mgr.yazi in-process: stubbed yazi API, fake cwd,
-- temp session store. No yazi, no terminal. Run from the plugin dir.
local fixture = "/tmp/session-mgr-test"
local session_dir = fixture .. "/yazi/session"

local H = {}
H.session_dir = session_dir

local function canonical(p)
	return io.popen("readlink -f " .. p):read("*l")
end
H.canonical = canonical

-- a, b are real dirs; link is a symlink to a (symlink matching is part of the plugin).
function H.reset()
	os.execute("rm -rf " .. fixture)
	os.execute("mkdir -p " .. session_dir .. " " .. fixture .. "/a " .. fixture .. "/b " .. fixture .. "/c")
	os.execute("ln -s a " .. fixture .. "/link")
	os.execute("touch " .. fixture .. "/c/README.md")
end

-- Mirrors the plugin's own filename scheme: <djb2 hash 8>_<sanitized last component>.lua
function H.session_path(canonical_cwd)
	local h = 5381
	for i = 1, #canonical_cwd do
		h = ((h * 33) + string.byte(canonical_cwd, i)) % 0xFFFFFFFF
	end
	local last = canonical_cwd:match("([^/]+)$"):gsub("[^%w%.%-]", "_")
	return session_dir .. "/" .. string.format("%08x", h):sub(1, 8) .. "_" .. last .. ".lua"
end

-- tabs: list of raw cwd strings (may be symlinked variants, which the plugin normalizes).
local pref_fields = {
	sort_by = "natural",
	sort_sensitive = false,
	sort_reverse = true,
	dir_first = true,
	sort_translit = false,
	linemode = "ino",
	show_hidden = true,
}
local pref_order = { "sort_by", "sort_sensitive", "sort_reverse", "dir_first", "sort_translit", "linemode", "show_hidden" }

local function pref_value(k)
	local v = pref_fields[k]
	if type(v) == "boolean" then
		return v and "true" or "false"
	end
	return string.format("%q", v)
end

-- tabs: list of raw cwd strings (may be symlinked variants, which the plugin normalizes).
-- name_key overrides the path the filename hash is computed from (stale/symlinked names).
function H.write_session(canonical_cwd, tabs, active_idx, name_key)
	local f = assert(io.open(H.session_path(name_key or canonical_cwd), "w"))
	local lines = {
		"return {",
		'  ["cwd"] = ' .. string.format("%q", canonical_cwd) .. ",",
		'  ["active_idx"] = ' .. tostring(active_idx) .. ",",
		'  ["tabs"] = {',
	}
	for i, cwd in ipairs(tabs) do
		lines[#lines + 1] = "    [" .. i .. "] = {"
		lines[#lines + 1] = "      [\"cwd\"] = " .. string.format("%q", cwd) .. ","
		for _, k in ipairs(pref_order) do
			lines[#lines + 1] = "      [\"" .. k .. "\"] = " .. pref_value(k) .. ","
		end
		lines[#lines + 1] = "    },"
	end
	lines[#lines + 1] = "  },"
	lines[#lines + 1] = "}"
	f:write(table.concat(lines, "\n") .. "\n")
	f:close()
end

local function fake_tab(cwd)
	return {
		current = { cwd = cwd },
		pref = {
			sort_by = "natural",
			sort_sensitive = false,
			sort_reverse = true,
			dir_first = true,
			sort_translit = false,
			linemode = "ino",
			show_hidden = true,
		},
	}
end

-- opts: cwd = startup dir, tabs = tabs currently open in yazi, idx = active tab,
-- fzf_output/fzf_code = canned fzf result for chooser tests.
function H.new(opts)
	opts = opts or {}
	local state = { emits = {}, notices = {}, permits = 0 }
	local env = setmetatable({}, { __index = _G })
	env.Url = function(s) return tostring(s) end
	env.ya = {
		quote = function(s) return '"' .. s .. '"' end,
		emit = function(name, arg) state.emits[#state.emits + 1] = { name = name, arg = arg } end,
		notify = function(n) state.notices[#state.notices + 1] = n.content end,
		-- ya.sync(f) hands f an internal _state as its first argument. LuaJIT drops the
		-- return of `return f(nil, ...)` (tail call with mixed fixed/vararg args), so
		-- capture the value explicitly.
		sync = function(f) return function(...) local r = f(nil, ...); return r end end,
	}
	env.cx = { tabs = { idx = opts.idx or 1 } }
	for i, cwd in ipairs(opts.tabs or {}) do
		env.cx.tabs[i] = fake_tab(cwd)
	end
	env.fs = { cwd = function() return opts.cwd end }
	env.ui = {
		hide = function()
			state.permits = state.permits + 1
			return { drop = function() state.permits = state.permits - 1 end }
		end,
	}
	if opts.fzf_output then
		local child = {
			write_all = function() end,
			flush = function() end,
			wait_with_output = function() return { stdout = opts.fzf_output, status = { code = opts.fzf_code or 0 } } end,
		}
		-- Lua 5.1 functions can't carry fields, so Command is a callable table.
		env.Command = setmetatable({ PIPED = "piped" }, {
			__call = function()
				local builder
				builder = {
					arg = function() return builder end,
					stdin = function() return builder end,
					stdout = function() return builder end,
					spawn = function() return child end,
				}
				return builder
				end,
		})
	end

	-- The plugin reads yazi's CLI argument from /proc/self/cmdline; always fake it so the
	-- test runner's own argv cannot leak in. opts.argv defaults to a plain `yazi` (no arg).
	local fake_io = setmetatable({}, { __index = _G.io })
	local real_open = _G.io.open
	fake_io.open = function(path, mode)
		if path == "/proc/self/cmdline" then
			local blob = table.concat(opts.argv or { "yazi" }, "\0") .. "\0"
			return { read = function() return blob end, close = function() end }
		end
		return real_open(path, mode)
	end
	env.io = fake_io

	local M = loadfile(opts.plugin or os.getenv("PLUGIN") or "./main.lua", "t", env)()
	-- Pins the session dir without restoring: run H.reset() before H.new().
	if M.setup then
		M.setup({}, { data_home = fixture })
	end
	return M, state
end

-- Args of every emitted command with this name.
function H.emitted(state, name)
	local out = {}
	for _, e in ipairs(state.emits) do
		if e.name == name then out[#out + 1] = e.arg end
	end
	return out
end

-- Args of the first emitted command with this name.
function H.arg(state, name)
	return H.emitted(state, name)[1]
end

function H.tab_dirs(state)
	local out = {}
	for _, e in ipairs(state.emits) do
		if e.name == "cd" or e.name == "tab_create" then out[#out + 1] = canonical(e.arg[1]) end
	end
	return out
end

return H
