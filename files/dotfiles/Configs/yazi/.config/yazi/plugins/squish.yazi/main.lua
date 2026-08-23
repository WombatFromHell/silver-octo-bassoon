-- ─────────────────────────────────────────────────────────────────────────────
-- Constants
-- ─────────────────────────────────────────────────────────────────────────────
local PLUGIN_NAME = "Squish"
local DEFAULT_TIMEOUT = 3.0
local DEFAULT_SQUISH_CMD = "squish"
local DEFAULT_UNSQUISH_CMD = "unsquish"

local NOTIFY_IDS = {
	BUILD = "squish-build",
	EXTRACT = "squish-extract",
	MOUNT = "squish-mount",
	UNMOUNT = "squish-unmount",
}

local MESSAGES = {
	START_BUILD = "Starting build...",
	BUILD_SUCCESS = function(target)
		return "Built: " .. target
	end,
	BUILD_ERROR = "Build failed",
	START_EXTRACT = "Starting extraction...",
	EXTRACT_SUCCESS = "Extracted successfully",
	EXTRACT_ERROR = "Extraction failed",
	START_MOUNT = "Attempting to mount...",
	MOUNT_SUCCESS = "Mounted successfully",
	MOUNT_ERROR = "Mount failed",
	UNMOUNT_SUCCESS = "Unmounted successfully",
	UNMOUNT_ERROR = "Unmount failed",
	NO_SELECTION = "No item selected",
	NEED_SQSH = "Select a .sqsh file",
	FILE_NOT_FOUND = function(url)
		return "File does not exist: " .. url
	end,
	UNKNOWN_ACTION = function(a)
		return "Unknown action: " .. a
	end,
	USAGE = "Usage: squish -- <build|extract|extract-pick|mount|unmount>",
	CMD_FAILED = "Failed to execute command",
}

local CONFIG = {
	timeout = DEFAULT_TIMEOUT,
	squish_cmd = DEFAULT_SQUISH_CMD,
	unsquish_cmd = DEFAULT_UNSQUISH_CMD,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Sync context for accessing cx
-- ─────────────────────────────────────────────────────────────────────────────
local get_hovered = ya.sync(function()
	local h = cx.active.current.hovered
	if not h then
		return nil
	end
	return {
		url = tostring(h.url),
		name = h.name,
		is_dir = h.cha.is_dir,
	}
end)

-- ponytail: cx.active.selected is a map, so item order is arbitrary;
-- fine for bundling into an archive. Falls back to the hovered item
-- (like dnd.lua does) so a single hover still builds
local get_selected = ya.sync(function()
	local items = {}
	-- ponytail: cx.active.selected iterates as (index, url); capture the value.
	-- .url guards both Url values and File values across yazi versions.
	for _, u in pairs(cx.active.selected) do
		items[#items + 1] = tostring(u.url or u)
	end
	if #items == 0 then
		local h = cx.active.current.hovered
		if h then
			items[#items + 1] = tostring(h.url)
		end
	end
	return items
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────
local function notify(content, level, id, timeout)
	ya.notify({
		title = PLUGIN_NAME,
		content = content,
		level = level or "info",
		timeout = timeout or CONFIG.timeout,
		id = id,
	})
end

local function is_sqsh_file(path)
	local lower = path:lower()
	return lower:match("%.sqsh$") or lower:match("%.squashfs$")
end

local function parse_list_mounts_line(line)
	local archive, mountpoint = line:match("^(.-)%s*%->%s*(.+)$")
	if archive and mountpoint then
		return archive, mountpoint
	end
	return nil, nil
end

local function get_mountpoint_display(mountpoint)
	return mountpoint:match("([^/]+)[/]?$") or mountpoint
end

local function get_tracked_mounts()
	local mounts = {}
	local handle = io.popen(CONFIG.squish_cmd .. " --list-mounts 2>/dev/null")
	if not handle then
		return mounts
	end

	for line in handle:lines() do
		local archive, mountpoint = parse_list_mounts_line(line)
		if archive and mountpoint then
			table.insert(mounts, {
				archive = archive,
				mountpoint = mountpoint,
				display = get_mountpoint_display(mountpoint),
			})
		end
	end
	handle:close()
	return mounts
end

local function validate_build(items)
	if #items == 0 then
		return false, MESSAGES.NO_SELECTION
	end
	return true
end

local function validate_hovered(action, h)
	if not h then
		return false, MESSAGES.NO_SELECTION
	end

	if not is_sqsh_file(h.url) then
		return false, MESSAGES.NEED_SQSH
	end

	local cha = fs.cha(Url(h.url))
	if not cha then
		return false, MESSAGES.FILE_NOT_FOUND(h.url)
	end

	return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Command Builders
-- ─────────────────────────────────────────────────────────────────────────────
local function build_squish_cmd(items, target)
	local sources = {}
	for _, u in ipairs(items) do
		table.insert(sources, ya.quote(u))
	end
	return string.format("%s --pipe %s -o %s", CONFIG.squish_cmd, table.concat(sources, " "), ya.quote(target))
end

local function build_unsquish_cmd(file_url, extract_path)
	if extract_path and extract_path ~= "" then
		return string.format("%s --pipe -o %s %s", CONFIG.unsquish_cmd, ya.quote(extract_path), ya.quote(file_url))
	end
	return string.format("%s --pipe %s", CONFIG.unsquish_cmd, ya.quote(file_url))
end

local function build_mount_cmd(file_url)
	return string.format("%s -m %s", CONFIG.squish_cmd, ya.quote(file_url))
end

local function build_unmount_cmd(file_url)
	return string.format("%s -u %s", CONFIG.squish_cmd, ya.quote(file_url))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Command Execution
-- ─────────────────────────────────────────────────────────────────────────────
-- ponytail: squish prints its own "Compression failed" wrapper as the LAST
-- stderr line; the real cause is the underlying tool's error just before it.
-- Show the last few lines so mksquashfs's message isn't masked.
local function err_detail(lines)
	local n = #lines
	if n == 0 then
		return nil
	end
	local start = math.max(1, n - 2)
	local out = {}
	for i = start, n do
		out[#out + 1] = lines[i]
	end
	return table.concat(out, " | ")
end

local function run_with_pipe_progress(cmd_str, notify_id, title_start)
	local child, err = Command("sh"):arg({ "-c", cmd_str }):stdout(Command.PIPED):stderr(Command.PIPED):spawn()
	if not child then
		return false, MESSAGES.CMD_FAILED
	end

	local last_pct = -1
	local err_lines = {}

	while true do
		local line, event = child:read_line()
		if event == 2 then
			break
		elseif event == 1 then
			local msg = line and line:match("^%s*(.-)%s*$")
			if msg and msg ~= "" then
				err_lines[#err_lines + 1] = msg
			end
		else
			local pct = tonumber(line)
			if pct and pct >= 0 and pct <= 100 then
				local display_pct = math.floor(pct / 20) * 20
				if (display_pct > last_pct and display_pct > 0) or pct == 100 then
					notify(string.format("%s %d%%", title_start, pct == 100 and 100 or display_pct), "info", notify_id, 2)
					last_pct = display_pct
				end
			end
		end
	end

	local status = child:wait()
	local success = status and status.success
	local detail
	if not success then
		detail = err_detail(err_lines) or (err and tostring(err)) or "no output"
	end
	return success, detail
end

local function run_simple_command(cmd_str, notify_id, start_msg, success_msg, error_msg)
	notify(start_msg, "info", notify_id)
	local child, err = Command("sh"):arg({ "-c", cmd_str }):stdout(Command.PIPED):stderr(Command.PIPED):spawn()
	if not child then
		notify(error_msg, "error", notify_id)
		return false
	end

	local out = child:wait_with_output()
	if not out then
		notify(error_msg, "error", notify_id)
		return false
	end

	local success = out.status and out.status.success
	if success then
		notify(success_msg, "info", notify_id)
	else
		local detail = out.stderr and out.stderr:match("[^\n]*%S[^\n]*%s*$") or ""
		notify(error_msg .. (detail ~= "" and (": " .. detail) or ""), "error", notify_id)
	end

	return success
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Operations
-- ─────────────────────────────────────────────────────────────────────────────
local function run_build(items)
	local target
	if #items == 1 then
		target = items[1] .. ".sqsh"
	else
		-- ponytail: date-named in the first item's parent dir; on collision
		-- squish falls back to its archive-YYYYMMDD-N naming
		local parent = tostring(Url(items[1]).parent)
		target = parent .. "/archive-" .. os.date("%Y%m%d") .. ".sqsh"
	end
	local cmd = build_squish_cmd(items, target)
	notify(MESSAGES.START_BUILD, "info", NOTIFY_IDS.BUILD)

	local success, detail = run_with_pipe_progress(cmd, NOTIFY_IDS.BUILD, "Building:")
	if success then
		notify(MESSAGES.BUILD_SUCCESS(target), "info", NOTIFY_IDS.BUILD)
		ya.emit("refresh", {})
	else
		notify(MESSAGES.BUILD_ERROR .. ": " .. (detail or "unknown"), "error", NOTIFY_IDS.BUILD)
	end
end

local function run_extract(file_url, extract_path)
	local cmd = build_unsquish_cmd(file_url, extract_path)
	notify(MESSAGES.START_EXTRACT, "info", NOTIFY_IDS.EXTRACT)

	local success, detail = run_with_pipe_progress(cmd, NOTIFY_IDS.EXTRACT, "Extracting:")
	if success then
		notify(MESSAGES.EXTRACT_SUCCESS, "info", NOTIFY_IDS.EXTRACT)
		ya.emit("refresh", {})
	else
		notify(MESSAGES.EXTRACT_ERROR .. ": " .. (detail or "unknown"), "error", NOTIFY_IDS.EXTRACT)
	end
end

local function run_extract_pick(file_url)
	local default_path = file_url:gsub("%.[^.]+$", "")
	local value, event = ya.input({
		title = "Extract to:",
		pos = { "center", w = 50 },
		value = default_path,
	})

	if event ~= 1 or not value or value == "" then
		return
	end

	run_extract(file_url, value)
end

local function run_mount(file_url)
	local cmd = build_mount_cmd(file_url)
	run_simple_command(cmd, NOTIFY_IDS.MOUNT, MESSAGES.START_MOUNT, MESSAGES.MOUNT_SUCCESS, MESSAGES.MOUNT_ERROR)
end

local function run_unmount(file_url)
	local cmd = build_unmount_cmd(file_url)
	if
		run_simple_command(
			cmd,
			NOTIFY_IDS.UNMOUNT,
			"Attempting to unmount...",
			MESSAGES.UNMOUNT_SUCCESS,
			MESSAGES.UNMOUNT_ERROR
		)
	then
		ya.emit("refresh", {})
	end
end

local function run_unmount_tracked()
	local mounts = get_tracked_mounts()
	if #mounts == 0 then
		notify("No tracked mounts found", "warn", NOTIFY_IDS.UNMOUNT)
		return
	end

	local cands = {}
	for i, m in ipairs(mounts) do
		local archive_name = m.archive:match("([^/]+)$") or m.archive
		table.insert(cands, { on = tostring(i), desc = string.format("%s -> %s/", archive_name, m.display) })
	end

	local idx = ya.which({
		title = "Unmount tracked mount",
		cands = cands,
	})

	if not idx then
		return
	end

	local selected = mounts[idx]
	local cmd = build_unmount_cmd(selected.archive)
	if
		run_simple_command(
			cmd,
			NOTIFY_IDS.UNMOUNT,
			"Attempting to unmount...",
			MESSAGES.UNMOUNT_SUCCESS,
			MESSAGES.UNMOUNT_ERROR
		)
	then
		ya.emit("refresh", {})
	end
end

local function run_jump()
	local mounts = get_tracked_mounts()
	if #mounts == 0 then
		notify("No tracked mounts found", "warn")
		return
	end

	local cands = {}
	for i, m in ipairs(mounts) do
		local archive_name = m.archive:match("([^/]+)$") or m.archive
		table.insert(cands, { on = tostring(i), desc = string.format("%s -> %s/", archive_name, m.display) })
	end

	local idx = ya.which({
		title = "Jump to mount",
		cands = cands,
	})

	if not idx then
		return
	end

	local selected = mounts[idx]
	ya.emit("tab_create", { tostring(Url(selected.mountpoint)) })
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Action dispatcher (composition pattern)
-- ─────────────────────────────────────────────────────────────────────────────
local ACTIONS = {
	extract = function(h, args)
		run_extract(h.url, args[2])
	end,
	["extract-pick"] = function(h)
		run_extract_pick(h.url)
	end,
	mount = function(h)
		run_mount(h.url)
	end,
	unmount = function(h)
		run_unmount(h.url)
	end,
	["unmount-tracked"] = function()
		run_unmount_tracked()
	end,
	jump = function()
		run_jump()
	end,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Setup & Entry
-- ─────────────────────────────────────────────────────────────────────────────
local M = {}

-- ponytail: yazi's spawned processes may not inherit the interactive shell's
-- PATH (~/.local/bin); resolve a bare name against the common user-install
-- location so `squish` is found without manual config. Absolute paths and
-- explicit opts pass through untouched.
local function resolve_exe(name)
	if name:match("/") then
		return name
	end
	local home = os.getenv("HOME") or ""
	for _, dir in ipairs({ home .. "/.local/bin", "/usr/local/bin" }) do
		local ok, cha = pcall(fs.cha, Url(dir .. "/" .. name))
		if ok and cha then
			return dir .. "/" .. name
		end
	end
	return name
end

function M.setup(_, opts)
	opts = opts or {}
	CONFIG.timeout = opts.timeout or DEFAULT_TIMEOUT
	CONFIG.squish_cmd = resolve_exe(opts.squish_cmd or DEFAULT_SQUISH_CMD)
	CONFIG.unsquish_cmd = resolve_exe(opts.unsquish_cmd or DEFAULT_UNSQUISH_CMD)
end

function M.entry(_, job)
	local action = job.args and job.args[1]
	if not action then
		notify(MESSAGES.USAGE, "error")
		return
	end

	if action == "build" then
		local items = get_selected()
		local ok, err = validate_build(items)
		if not ok then
			notify(err, "error")
			return
		end
		run_build(items)
		return
	end

	local handler = ACTIONS[action]
	if not handler then
		notify(MESSAGES.UNKNOWN_ACTION(action), "error")
		return
	end

	if action == "unmount-tracked" or action == "jump" then
		handler()
		return
	end

	local h = get_hovered()
	local ok, err = validate_hovered(action, h)
	if not ok then
		notify(err, "error")
		return
	end

	handler(h, job)
end

return M
