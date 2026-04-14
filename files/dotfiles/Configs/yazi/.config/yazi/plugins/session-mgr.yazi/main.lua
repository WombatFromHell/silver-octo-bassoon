-- session-mgr.yazi — named session persistence with auto-restore
--
-- Sessions are stored as Lua source under $XDG_DATA_HOME/yazi/session/
-- Session files use abbreviated hash-based names but store the full canonical
-- cwd for accurate matching on auto-load.
--
-- Actions (via `plugin session-mgr -- <action>`):
--   save-and-quit   — capture all tabs → write session file → quit
--   load <name>     — restore a saved session by name
--   chooser         — interactive session picker
--   delete <name>   — remove a saved session
--   save            — save session without quitting

-- Expand `~` to the actual home directory path (Lua's io.open/loadfile
-- do NOT understand `~`, and fs.expand_url only expands $VAR, not `~`).
local function expand_tilde(path)
	if path:sub(1, 2) == "~/" then
		return (os.getenv("HOME") or "") .. path:sub(2)
	elseif path == "~" then
		return os.getenv("HOME") or ""
	end
	return path
end

-- Get the session directory path, computing it lazily if setup hasn't run yet.
local function _session_dir_str()
	if SESSION_DIR_STR then
		return SESSION_DIR_STR
	end
	local data_home = os.getenv("XDG_DATA_HOME")
	if not data_home or data_home == "" then
		data_home = expand_tilde("~/.local/share")
	end
	SESSION_DIR_STR = data_home .. "/yazi/session"
	SESSION_DIR_URL = Url(SESSION_DIR_STR)
	os.execute("mkdir -p " .. ya.quote(SESSION_DIR_STR))
	return SESSION_DIR_STR
end

local M = {}

-- ── module state (set by setup) ──────────────────────────────────────────────
local SESSION_DIR_STR

-- ── SYNC FUNCTIONS (must be declared at top level) ───────────────────────────

local _get_current_session = ya.sync(function()
	local tabs = cx.tabs
	local session = { active_idx = tabs.idx, tabs = {} }
	for idx, tab in ipairs(tabs) do
		session.tabs[idx] = {
			cwd             = tostring(tab.current.cwd):gsub("\\", "/"),
			sort_by         = tab.pref.sort_by,
			sort_sensitive  = tab.pref.sort_sensitive,
			sort_reverse    = tab.pref.sort_reverse,
			sort_dir_first  = tab.pref.sort_dir_first,
			sort_translit   = tab.pref.sort_translit,
			linemode        = tab.pref.linemode,
			show_hidden     = tab.pref.show_hidden,
		}
	end
	return session
end)

local _restore_session = ya.sync(function(_state, session, from_setup)
	if not session or not session.tabs or #session.tabs == 0 then
		return
	end

	local total = #session.tabs

	-- During setup, yazi always starts with exactly 1 tab at fs.cwd().
	-- Just cd it and create the rest — no cleanup needed.
	if from_setup then
		local first = session.tabs[1]
		ya.emit("cd", { first.cwd })
		ya.emit("sort", {
			by        = first.sort_by,
			sensitive = first.sort_sensitive,
			reverse   = first.sort_reverse,
			dir_first = first.sort_dir_first,
			translit  = first.sort_translit,
		})
		ya.emit("linemode", { first.linemode })
		ya.emit("hidden", { first.show_hidden and "show" or "hide" })

		for idx = 2, total do
			local tab = session.tabs[idx]
			ya.emit("tab_create", { tab.cwd })
			ya.emit("sort", {
				by        = tab.sort_by,
				sensitive = tab.sort_sensitive,
				reverse   = tab.sort_reverse,
				dir_first = tab.sort_dir_first,
				translit  = tab.sort_translit,
			})
			ya.emit("linemode", { tab.linemode })
			ya.emit("hidden", { tab.show_hidden and "show" or "hide" })
		end

		local target = math.max(1, session.active_idx or 1) - 1
		ya.emit("tab_switch", { target })
		return
	end

	-- During manual load (entry context), cx is available.
	-- Reconcile existing tabs with the session.
	local count = #cx.tabs

	-- Apply settings to a tab
	local function apply(tab)
		ya.emit("sort", {
			by        = tab.sort_by,
			sensitive = tab.sort_sensitive,
			reverse   = tab.sort_reverse,
			dir_first = tab.sort_dir_first,
			translit  = tab.sort_translit,
		})
		ya.emit("linemode", { tab.linemode })
		ya.emit("hidden", { tab.show_hidden and "show" or "hide" })
	end

	-- Navigate existing tabs and cd them to session cwd
	for i = 1, math.min(count, total) do
		ya.emit("tab_switch", { i - 1 })
		ya.emit("cd", { session.tabs[i].cwd })
		apply(session.tabs[i])
	end

	-- Close excess tabs (from the back)
	if count > total then
		for i = count, total + 1, -1 do
			ya.emit("tab_close", { i })
		end
	end

	-- Create missing tabs (append after the last tab)
	if count < total then
		for i = count + 1, total do
			-- Switch to last tab so tab_create appends after it
			ya.emit("tab_switch", { math.max(0, i - 2) })
			ya.emit("tab_create", { session.tabs[i].cwd })
			apply(session.tabs[i])
		end
	end

	-- Switch to the tab that was active when saved
	local target = math.max(1, session.active_idx or 1) - 1
	ya.emit("tab_switch", { target })
end)

-- ── HELPERS ──────────────────────────────────────────────────────────────────

-- Resolve a path to its canonical absolute form (sync via readlink -f).
function M:_canonical(path)
	local pipe = io.popen("readlink -f " .. ya.quote(path) .. " 2>/dev/null")
	if pipe then
		local resolved = pipe:read("*l")
		pipe:close()
		if resolved and resolved ~= "" then
			return resolved
		end
	end
	return path
end

-- Normalize a path for comparison (remove trailing slash, collapse double slashes).
function M:_normalize(path)
	return path:gsub("\\", "/"):gsub("//+", "/"):gsub("/+$", "")
end

-- Simple DJB2 hash (sync, avoids async ya.hash and bit32).
function M:_hash(path)
	local h = 5381
	for i = 1, #path do
		h = ((h * 33) + string.byte(path, i)) % 0xFFFFFFFF
	end
	return string.format("%08x", h)
end

-- Generate an abbreviated session filename from a canonical path.
-- Returns a short string like `a1b2c3d4` (first 8 chars of hash) +
-- last path component for readability: `a1b2c3d4_Configs`
function M:_session_filename(canonical_cwd)
	local hash = self:_hash(canonical_cwd):sub(1, 8)
	local last = canonical_cwd:match("([^/]+)$") or "root"
	if last == "" then
		last = "root"
	end
	-- Sanitize last component for filename safety
	last = last:gsub("[^%w%.%-]", "_")
	return hash .. "_" .. last
end

-- Read and evaluate a Lua source file (sync).
function M:_load_session(path)
	local f, err = loadfile(path)
	if not f then
		return nil, err
	end
	return f()
end

-- Serialize a Lua value to source code (recursive).
function M:_serialize(val, indent)
	indent = indent or ""
	local t = type(val)
	if t == "nil" then
		return "nil"
	elseif t == "boolean" then
		return val and "true" or "false"
	elseif t == "number" then
		return tostring(val)
	elseif t == "string" then
		return string.format("%q", val)
	elseif t == "table" then
		local lines = {}
		table.insert(lines, "{")
		local next_indent = indent .. "  "
		for k, v in pairs(val) do
			local key_str
			if type(k) == "number" then
				key_str = string.format("[%d]", k)
			else
				key_str = string.format("[%s]", M:_serialize(k))
			end
			local val_str = M:_serialize(v, next_indent)
			table.insert(lines, string.format("%s%s = %s,", next_indent, key_str, val_str))
		end
		table.insert(lines, indent .. "}")
		return table.concat(lines, "\n")
	else
		return "nil"
	end
end

-- List all saved session files, returning {filename, canonical_cwd} pairs.
function M:_list_sessions()
	local sessions = {}
	local dir = _session_dir_str()

	local pipe = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
	if pipe then
		for name in pipe:lines() do
			local base = name:match("^(.-)%.lua$")
			if base then
				local path = dir .. "/" .. name
				local f = loadfile(path)
				if f then
					local session = f()
					if session and session.tabs and session.tabs[1] then
						-- Prefer stored canonical cwd; fall back to first tab's cwd (legacy)
						local cwd = session.cwd or M:_canonical(session.tabs[1].cwd)
						table.insert(sessions, { filename = base, cwd = cwd })
					end
				end
			end
		end
		pipe:close()
	end

	table.sort(sessions, function(a, b) return a.filename < b.filename end)
	return sessions
end

-- Find the session file for a canonical cwd by computing the expected filename.
-- Falls back to scanning all files for legacy sessions that used path-based names.
function M:_find_session(canonical_cwd)
	local dir = _session_dir_str()
	local expected = dir .. "/" .. M:_session_filename(canonical_cwd) .. ".lua"

	-- First try the hash-based name (new format)
	local f = loadfile(expected)
	if f then
		local session = f()
		if session then
			return expected, M:_session_filename(canonical_cwd)
		end
	end

	-- Fallback: scan all files for legacy sessions (path-based filenames)
	local pipe = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
	if pipe then
		for name in pipe:lines() do
			if name:match("%.lua$") then
				local path = dir .. "/" .. name
				local lf = loadfile(path)
				if lf then
					local session = lf()
					if session and session.tabs and session.tabs[1] then
						-- Legacy format: match by first tab's cwd
						local tab_cwd = M:_canonical(session.tabs[1].cwd)
						if tab_cwd == canonical_cwd then
							pipe:close()
							return path, name:match("^(.-)%.lua$")
						end
						-- New format: match by stored cwd
						if session.cwd == canonical_cwd then
							pipe:close()
							return path, name:match("^(.-)%.lua$")
						end
					end
				end
			end
		end
		pipe:close()
	end
	return nil, nil
end

-- Build the full session file path from a canonical cwd.
function M:_session_path(canonical_cwd)
	return _session_dir_str() .. "/" .. M:_session_filename(canonical_cwd) .. ".lua"
end

-- Resolve a user-supplied argument to a session file path.
-- If the arg looks like a filesystem path, convert to session filename;
-- otherwise treat as a raw session filename.
function M:_resolve_path(arg)
	if arg:find("[/\\]") then
		-- Treat as a path: find matching session by cwd
		local canonical = M:_canonical(arg)
		local path = M:_find_session(canonical)
		return path or M:_session_path(canonical)
	end
	return _session_dir_str() .. "/" .. arg .. ".lua"
end

-- ── ACTIONS ──────────────────────────────────────────────────────────────────

function M:save()
	local session = _get_current_session()
	local cwd = tostring(fs.cwd())
	local canonical = M:_canonical(cwd)

	session.cwd = canonical

	local path = M:_session_path(canonical)
	local source = "return " .. M:_serialize(session) .. "\n"

	os.execute("mkdir -p " .. ya.quote(_session_dir_str()))

	local f, err = io.open(path, "w")
	if f then
		f:write(source)
		f:close()
		print("Session saved: " .. canonical)
	else
		print("Cannot write session file: " .. tostring(err))
	end
end

function M:save_and_quit()
	local session = _get_current_session()
	local cwd = tostring(fs.cwd())
	local canonical = M:_canonical(cwd)
	session.cwd = canonical

	local path = M:_session_path(canonical)
	local source = "return " .. M:_serialize(session) .. "\n"

	os.execute("mkdir -p " .. ya.quote(_session_dir_str()))

	local f, err = io.open(path, "w")
	if f then
		f:write(source)
		f:close()
	else
		print("Cannot write session file: " .. tostring(err))
	end

	ya.emit("quit", {})
end

function M:load(arg)
	local path = M:_resolve_path(arg)

	local session, err = M:_load_session(path)
	if not session then
		print("No session found: " .. tostring(err) .. " — " .. arg)
		return
	end

	_restore_session(session)
	print("Session loaded: " .. arg)
end

function M:delete(arg)
	local path = M:_resolve_path(arg)

	local f = io.open(path, "r")
	if not f then
		print("Session not found: " .. path)
		return
	end
	f:close()

	local ok = os.remove(path)
	if ok then
		print("Session deleted: " .. arg)
	else
		print("Failed to delete session: " .. arg)
	end
end

function M:chooser()
	local sessions = self:_list_sessions()

	if #sessions == 0 then
		print("No saved sessions found")
		return
	end

	-- Build fzf input lines: "index<TAB>path"
	local lines = {}
	for i, s in ipairs(sessions) do
		table.insert(lines, string.format("%d\t%s", i, s.cwd))
	end
	local input = table.concat(lines, "\n")

	-- Hide yazi UI, run fzf, restore yazi UI
	local permit = ui.hide()

	local child, err = Command("fzf")
		:arg({
			"--header", "Enter=load  Ctrl-D=delete  TAB=toggle  Esc=quit",
			"--reverse",
			"--prompt", "session> ",
			"--multi",
			"--expect=ctrl-d",
		})
		:stdin(Command.PIPED)
		:stdout(Command.PIPED)
		:spawn()

	if child then
		child:write_all(input)
		child:flush()

		local output, cerr = child:wait_with_output()
		permit:drop()

		if not output then
			print("Cannot read fzf output: " .. tostring(cerr))
			return
		end

		-- fzf exit code 130 = Ctrl-C/Escape
		if output.status.code == 130 or not output.stdout or output.stdout == "" then
			return
		end

		-- With --expect, first line is the key pressed, rest are selections
		local key = output.stdout:match("^[^\r\n]*")
		local body = output.stdout:sub(#key + 2) -- skip key line + newline
		local mode = (key == "ctrl-d") and "delete" or "load"

		if mode == "delete" then
			local deleted = 0
			for line in body:gmatch("[^\r\n]+") do
				local idx = tonumber(line:match("^(%d+)"))
				if idx and sessions[idx] then
					local path = _session_dir_str() .. "/" .. sessions[idx].filename .. ".lua"
					if os.remove(path) then
						print("Deleted: " .. sessions[idx].cwd)
						deleted = deleted + 1
					end
				end
			end
			print(deleted .. " session(s) deleted")
		else
			-- Load single selected session (take first selection)
			local line = body:match("^[^\r\n]+")
			if line then
				local idx = tonumber(line:match("^(%d+)"))
				if idx and sessions[idx] then
					self:load(sessions[idx].filename)
				end
			end
		end
	else
		permit:drop()
		print("fzf not available")
	end
end

-- ── PLUGIN INTERFACE ─────────────────────────────────────────────────────────

function M.setup(_state, opts)
	opts = opts or {}
	local data_home = opts.data_home or os.getenv("XDG_DATA_HOME")
	if not data_home or data_home == "" then
		data_home = expand_tilde("~/.local/share")
	end
	SESSION_DIR_STR = data_home .. "/yazi/session"
	SESSION_DIR_URL = Url(SESSION_DIR_STR)

	os.execute("mkdir -p " .. ya.quote(SESSION_DIR_STR))

	-- Auto-restore session for the current working directory
	local cwd = tostring(fs.cwd())
	local canonical = M:_canonical(cwd)
	local dir = _session_dir_str()

	-- Try loading by the computed hash-based filename first (new format)
	local fname = M:_session_filename(canonical) .. ".lua"
	local path = dir .. "/" .. fname
	local session = M:_load_session(path)

	-- Fallback: scan for legacy sessions matching by first tab's cwd
	if not session then
		local norm = M:_normalize(canonical)
		local pipe = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
		if pipe then
			for name in pipe:lines() do
				if name:match("%.lua$") and name ~= fname then
					local p = dir .. "/" .. name
					local lf = loadfile(p)
					if lf then
						local s = lf()
						if s and s.tabs and s.tabs[1] then
							local tc = M:_normalize(M:_canonical(s.tabs[1].cwd))
							if tc == norm then
								session = s
								break
							end
						end
					end
				end
			end
			pipe:close()
		end
	end

	if session then
		_restore_session(session, true)
	end
end

function M.entry(self, job)
	local action = job.args[1]
	if action == "save" then
		self:save()
	elseif action == "save-and-quit" then
		self:save_and_quit()
	elseif action == "load" then
		self:load(job.args[2] or "")
	elseif action == "chooser" then
		self:chooser()
	elseif action == "delete" then
		self:delete(job.args[2] or "")
	end
end

return M
