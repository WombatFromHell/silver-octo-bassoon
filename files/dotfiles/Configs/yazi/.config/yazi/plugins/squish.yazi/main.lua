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
	BUILD_SUCCESS = function(target) return "Built: " .. target end,
	BUILD_ERROR = "Build failed",
	START_EXTRACT = "Starting extraction...",
	EXTRACT_SUCCESS = "Extracted successfully",
	EXTRACT_ERROR = "Extraction failed",
	MOUNT_SUCCESS = "Mounted successfully",
	MOUNT_ERROR = "Mount failed",
	UNMOUNT_SUCCESS = "Unmounted successfully",
	UNMOUNT_ERROR = "Unmount failed",
	NO_SELECTION = "No item selected",
	NEED_DIRECTORY = "Select a directory to compress",
	NEED_SQSH = "Select a .sqsh file",
	FILE_NOT_FOUND = function(url) return "File does not exist: " .. url end,
	UNKNOWN_ACTION = function(a) return "Unknown action: " .. a end,
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

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────
local function notify(content, level, id)
	ya.notify({
		title = PLUGIN_NAME,
		content = content,
		level = level or "info",
		timeout = CONFIG.timeout,
		id = id,
	})
end

local function is_sqsh_file(path)
	return path:lower():match("%.sqsh$")
end

local function validate_hovered(action, h)
	if not h then
		return false, MESSAGES.NO_SELECTION
	end

	if action == "build" then
		if not h.is_dir then
			return false, MESSAGES.NEED_DIRECTORY
		end
		return true
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
local function build_squish_cmd(dir_url, target)
	return string.format("%s --pipe %s -o %s", CONFIG.squish_cmd, ya.quote(dir_url), ya.quote(target))
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
local function run_with_pipe_progress(cmd, notify_id, title_start)
	local handle = io.popen(cmd, "r")
	if not handle then
		notify(MESSAGES.CMD_FAILED, "error", notify_id)
		return false
	end

	local last_pct = -1

	while true do
		local line = handle:read("*l")
		if not line then
			break
		end

		local pct = tonumber(line)
		if pct and pct >= 0 and pct <= 100 then
			notify(string.format("%s %d%%", title_start, pct), "info", notify_id)
			last_pct = pct
		end
	end

	local ok = handle:close()
	return ok and (last_pct == 100 or last_pct == -1)
end

local function run_simple_command(cmd, notify_id, success_msg, error_msg)
	notify(success_msg .. "...", "info", notify_id)
	local result = os.execute(cmd .. " >/dev/null 2>&1")
	local success = (result == 0 or result == true)

	if success then
		notify(success_msg, "info", notify_id)
	else
		notify(error_msg, "error", notify_id)
	end

	return success
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Result Handler
-- ─────────────────────────────────────────────────────────────────────────────
local function handle_result(success, success_msg, error_msg, id, opts)
	opts = opts or {}
	if success then
		notify(success_msg, "info", id)
		if opts.refresh then
			ya.emit("refresh", {})
		end
	else
		notify(error_msg, "error", id)
	end
	return success
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Progress Operation Abstraction
-- ─────────────────────────────────────────────────────────────────────────────
local function run_progress_operation(opts)
	notify(opts.start_msg, "info", opts.notify_id)
	local cmd = opts.build_cmd()
	local success = run_with_pipe_progress(cmd, opts.notify_id, opts.progress_prefix)
	return handle_result(success, opts.success_msg, opts.error_msg, opts.notify_id, { refresh = opts.refresh })
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Operations (composed functions)
-- ─────────────────────────────────────────────────────────────────────────────
local function run_build(dir_url)
	local target = dir_url .. ".sqsh"
	run_progress_operation({
		notify_id = NOTIFY_IDS.BUILD,
		start_msg = MESSAGES.START_BUILD,
		progress_prefix = "Building:",
		build_cmd = function() return build_squish_cmd(dir_url, target) end,
		success_msg = MESSAGES.BUILD_SUCCESS(target),
		error_msg = MESSAGES.BUILD_ERROR,
		refresh = true,
	})
end

local function run_extract(file_url, extract_path)
	run_progress_operation({
		notify_id = NOTIFY_IDS.EXTRACT,
		start_msg = MESSAGES.START_EXTRACT,
		progress_prefix = "Extracting:",
		build_cmd = function() return build_unsquish_cmd(file_url, extract_path) end,
		success_msg = MESSAGES.EXTRACT_SUCCESS,
		error_msg = MESSAGES.EXTRACT_ERROR,
		refresh = true,
	})
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
	run_simple_command(cmd, NOTIFY_IDS.MOUNT, MESSAGES.MOUNT_SUCCESS, MESSAGES.MOUNT_ERROR)
end

local function run_unmount(file_url)
	local cmd = build_unmount_cmd(file_url)
	if run_simple_command(cmd, NOTIFY_IDS.UNMOUNT, MESSAGES.UNMOUNT_SUCCESS, MESSAGES.UNMOUNT_ERROR) then
		ya.emit("refresh", {})
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Action dispatcher (composition pattern)
-- ─────────────────────────────────────────────────────────────────────────────
local ACTIONS = {
	build = function(h) run_build(h.url) end,
	extract = function(h, args) run_extract(h.url, args[2]) end,
	["extract-pick"] = function(h) run_extract_pick(h.url) end,
	mount = function(h) run_mount(h.url) end,
	unmount = function(h) run_unmount(h.url) end,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Setup & Entry
-- ─────────────────────────────────────────────────────────────────────────────
local M = {}

function M.setup(_, opts)
	opts = opts or {}
	CONFIG.timeout = opts.timeout or DEFAULT_TIMEOUT
	CONFIG.squish_cmd = opts.squish_cmd or DEFAULT_SQUISH_CMD
	CONFIG.unsquish_cmd = opts.unsquish_cmd or DEFAULT_UNSQUISH_CMD
end

function M.entry(_, job)
	local action = job.args and job.args[1]
	if not action then
		notify(MESSAGES.USAGE, "error")
		return
	end

	local h = get_hovered()
	local ok, err = validate_hovered(action, h)
	if not ok then
		notify(err, "error")
		return
	end

	local handler = ACTIONS[action]
	if handler then
		handler(h, job.args)
	else
		notify(MESSAGES.UNKNOWN_ACTION(action), "error")
	end
end

return M
