-- session-mgr.yazi — named session persistence with auto-restore
--
-- Sessions are stored as Lua source under $XDG_DATA_HOME/yazi/session/
-- Session files use abbreviated hash-based names but store the full canonical
-- cwd for accurate matching on auto-load.
--
-- Actions (via `plugin session-mgr -- <action>`):
-- save-and-quit — capture all tabs → write session file → quit
-- load <name> — restore a saved session by name
-- chooser — interactive session picker
-- delete <name> — remove a saved session
-- save — save session without quitting

local CANCEL_CODE = 130

local function expand_tilde(path)
	if path:sub(1, 2) == "~/" then
		return (os.getenv("HOME") or "") .. path:sub(2)
	elseif path == "~" then
		return os.getenv("HOME") or ""
	end
	return path
end

local function _session_dir_str(data_home)
	if SESSION_DIR_STR then
		return SESSION_DIR_STR
	end
	if not data_home then
		data_home = os.getenv("XDG_DATA_HOME")
	end
	if not data_home or data_home == "" then
		data_home = expand_tilde("~/.local/share")
	end
	SESSION_DIR_STR = data_home .. "/yazi/session"
	SESSION_DIR_URL = Url(SESSION_DIR_STR)
	os.execute("mkdir -p " .. ya.quote(SESSION_DIR_STR))
	return SESSION_DIR_STR
end

local function _session_path(filename)
	return _session_dir_str() .. "/" .. filename .. ".lua"
end

local function _notify(msg, level)
	ya.notify({ title = "session-mgr", content = msg, timeout = 3, level = level or "info" })
end

local function _notify_error(msg)
	_notify(msg, "error")
end

local M = {}

local SESSION_DIR_STR

local _get_current_session = ya.sync(function()
	local tabs = cx.tabs
	local session = { active_idx = tabs.idx, tabs = {} }
	for idx, tab in ipairs(tabs) do
		session.tabs[idx] = {
			cwd = tostring(tab.current.cwd):gsub("\\", "/"),
			sort_by = tab.pref.sort_by,
			sort_sensitive = tab.pref.sort_sensitive,
			sort_reverse = tab.pref.sort_reverse,
			sort_dir_first = tab.pref.sort_dir_first,
			sort_translit = tab.pref.sort_translit,
			linemode = tab.pref.linemode,
			show_hidden = tab.pref.show_hidden,
		}
	end
	return session
end)

local function _prepare_session()
	local session = _get_current_session()
	local cwd = tostring(fs.cwd())
	local canonical = M:_canonical(cwd)
	session.cwd = canonical
	return session, canonical
end

local _apply_tab_prefs = ya.sync(function(_state, tab)
	ya.emit("sort", {
		by = tab.sort_by,
		sensitive = tab.sort_sensitive,
		reverse = tab.sort_reverse,
		dir_first = tab.sort_dir_first,
		translit = tab.sort_translit,
	})
	ya.emit("linemode", { tab.linemode })
	ya.emit("hidden", { tab.show_hidden and "show" or "hide" })
end)

local _close_all_tabs = ya.sync(function(_state)
	for i = #cx.tabs, 1, -1 do
		ya.emit("tab_switch", { 0 })
		ya.emit("tab_close", {})
	end
end)

local _restore_tabs = ya.sync(function(_state, session)
	local total = #session.tabs
	for i = 2, total do
		ya.emit("tab_create", { session.tabs[i].cwd })
		_apply_tab_prefs(session.tabs[i])
	end
	ya.emit("tab_switch", { math.max(1, session.active_idx or 1) - 1 })
end)

local _restore_session = ya.sync(function(_state, session, from_setup)
	if not session or not session.tabs or #session.tabs == 0 then
		return
	end

	if from_setup then
		ya.emit("cd", { session.tabs[1].cwd })
		_apply_tab_prefs(session.tabs[1])
		for i = 2, #session.tabs do
			ya.emit("tab_create", { session.tabs[i].cwd })
			_apply_tab_prefs(session.tabs[i])
		end
		ya.emit("tab_switch", { math.max(1, session.active_idx or 1) - 1 })
		return
	end

	_close_all_tabs()
	ya.emit("cd", { session.tabs[1].cwd })
	_apply_tab_prefs(session.tabs[1])
	_restore_tabs(session)
end)

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

function M:_normalize(path)
	path = path:gsub("\\", "/")
	path = path:gsub("/+", "/")
	return path:gsub("/+$", "")
end

function M:_hash(path)
	local h = 5381
	for i = 1, #path do
		h = ((h * 33) + string.byte(path, i)) % 0xFFFFFFFF
	end
	return string.format("%08x", h)
end

function M:_session_filename(canonical_cwd)
	local hash = self:_hash(canonical_cwd):sub(1, 8)
	local last = canonical_cwd:match("([^/]+)$") or "root"
	if last == "" then
		last = "root"
	end
	last = last:gsub("[^%w%.%-]", "_")
	return hash .. "_" .. last
end

function M:_load_session(path)
	local f, err = loadfile(path)
	if not f then
		return nil, err
	end
	return f()
end

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
		local next_indent = indent .. " "
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

local function _was_cancelled(output)
	return output.status.code == CANCEL_CODE or not output.stdout or output.stdout == ""
end

function M:_list_sessions()
	local sessions = {}
	local dir = _session_dir_str()

	local pipe = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
	if pipe then
		for name in pipe:lines() do
			local base = name:match("^(.-)%.lua$")
			if base then
				local session = loadfile(_session_path(base))
				if session then
					session = session()
					if session and session.tabs and session.tabs[1] then
						table.insert(sessions, {
							filename = base,
							cwd = session.cwd or M:_canonical(session.tabs[1].cwd),
						})
					end
				end
			end
		end
		pipe:close()
	end

	table.sort(sessions, function(a, b)
		return a.filename < b.filename
	end)
	return sessions
end

function M:_find_session(canonical_cwd)
	local expected_name = M:_session_filename(canonical_cwd)
	local expected_path = _session_path(expected_name)

	local session = loadfile(expected_path)
	if session then
		session = session()
		if session then
			return expected_path, expected_name
		end
	end

	local norm = M:_normalize(canonical_cwd)
	local dir = _session_dir_str()
	local pipe = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
	if pipe then
		for name in pipe:lines() do
			if name:match("%.lua$") and name ~= expected_name .. ".lua" then
				local path = dir .. "/" .. name
				local lf = loadfile(path)
				if lf then
					session = lf()
					if session and session.tabs and session.tabs[1] then
						local tab_cwd = M:_normalize(M:_canonical(session.tabs[1].cwd))
						if tab_cwd == norm or session.cwd == canonical_cwd then
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

function M:_session_path_from_cwd(canonical_cwd)
	return _session_path(M:_session_filename(canonical_cwd))
end

function M:_resolve_path(arg)
	if arg:find("[/\\]") then
		local canonical = M:_canonical(arg)
		local path = M:_find_session(canonical)
		return path or M:_session_path_from_cwd(canonical)
	end
	return _session_path(arg)
end

local function _write_session(canonical, session)
	local path = M:_session_path_from_cwd(canonical)
	local source = "return " .. M:_serialize(session) .. "\n"
	local f, err = io.open(path, "w")
	if f then
		f:write(source)
		f:close()
		return true
	end
	return false, err
end

function M:_save(quit_after)
	local session, canonical = _prepare_session()
	local ok, err = _write_session(canonical, session)
	if ok then
		_notify("Session saved: " .. canonical)
	else
		_notify_error("Cannot write session file: " .. tostring(err))
	end
	if quit_after then
		ya.emit("quit", {})
	end
end

local function _load_and_restore(arg)
	local path = M:_resolve_path(arg)
	local session, err = M:_load_session(path)
	if not session then
		_notify_error("No session found: " .. tostring(err) .. " — " .. arg)
		return false
	end
	_restore_session(session)
	_notify("Session loaded: " .. arg)
	return true
end

local function _delete_session_by_filename(filename)
	local path = _session_path(filename)
	local f = io.open(path, "r")
	if not f then
		return false
	end
	f:close()
	return os.remove(path)
end

function M:load(arg)
	_load_and_restore(arg)
end

function M:delete(arg)
	local path = M:_resolve_path(arg)
	local f = io.open(path, "r")
	if not f then
		_notify_error("Session not found: " .. path)
		return
	end
	f:close()

	if os.remove(path) then
		_notify("Session deleted: " .. arg)
	else
		_notify_error("Failed to delete session: " .. arg)
	end
end

local function _build_fzf_input(sessions)
	local lines = {}
	for i, s in ipairs(sessions) do
		table.insert(lines, string.format("%d\t%s", i, s.cwd))
	end
	return table.concat(lines, "\n")
end

local function _spawn_fzf_chooser(input)
	return Command("fzf")
		:arg({
			"--header",
			"Enter=load Ctrl-D=delete TAB=toggle Esc=quit",
			"--reverse",
			"--prompt",
			"session> ",
			"--multi",
			"--expect=ctrl-d",
		})
		:stdin(Command.PIPED)
		:stdout(Command.PIPED)
		:spawn()
end

local function _parse_fzf_output(output)
	local key = output.stdout:match("^[^\r\n]*")
	local body = output.stdout:sub(#key + 2)
	local mode = (key == "ctrl-d") and "delete" or "load"
	local indices = {}
	for line in body:gmatch("[^\r\n]+") do
		local idx = tonumber(line:match("^(%d+)"))
		if idx then
			table.insert(indices, idx)
		end
	end
	return mode, indices
end

local function _handle_chooser_delete(sessions, indices)
	local deleted = 0
	for _, idx in ipairs(indices) do
		if sessions[idx] then
			if _delete_session_by_filename(sessions[idx].filename) then
				_notify("Deleted: " .. sessions[idx].cwd)
				deleted = deleted + 1
			end
		end
	end
	_notify(deleted .. " session(s) deleted")
end

local function _handle_chooser_load(sessions, indices, permit)
	local idx = indices[1]
	if not idx or not sessions[idx] then
		permit:drop()
		return
	end
	local session, err = M:_load_session(_session_path(sessions[idx].filename))
	if session then
		_restore_session(session)
		permit:drop()
	else
		permit:drop()
		_notify_error("Failed to load session: " .. tostring(err))
	end
end

function M:chooser()
	local sessions = self:_list_sessions()

	if #sessions == 0 then
		_notify("No saved sessions found")
		return
	end

	local input = _build_fzf_input(sessions)
	local permit = ui.hide()

	local child, err = _spawn_fzf_chooser(input)
	if not child then
		permit:drop()
		_notify_error("fzf not available: " .. tostring(err))
		return
	end

	child:write_all(input)
	child:flush()

	local output, cerr = child:wait_with_output()
	if not output then
		permit:drop()
		_notify_error("Cannot read fzf output: " .. tostring(cerr))
		return
	end

	if _was_cancelled(output) then
		permit:drop()
		return
	end

	local mode, indices = _parse_fzf_output(output)

	if mode == "delete" then
		permit:drop()
		_handle_chooser_delete(sessions, indices)
	else
		_handle_chooser_load(sessions, indices, permit)
	end
end

function M.setup(_state, opts)
	opts = opts or {}
	_session_dir_str(opts.data_home)

	local cwd = tostring(fs.cwd())
	local canonical = M:_canonical(cwd)
	local path = M:_find_session(canonical)
	if path then
		local session = M:_load_session(path)
		if session then
			_restore_session(session, true)
		end
	end
end

function M.entry(self, job)
	local action = job.args[1]
	if action == "save" then
		self:_save(false)
	elseif action == "save-and-quit" then
		self:_save(true)
	elseif action == "load" then
		self:load(job.args[2] or "")
	elseif action == "chooser" then
		self:chooser()
	elseif action == "delete" then
		self:delete(job.args[2] or "")
	end
end

return M
