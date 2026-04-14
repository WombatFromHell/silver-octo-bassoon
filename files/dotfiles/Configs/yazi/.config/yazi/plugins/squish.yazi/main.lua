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
-- Run command in pipe mode: read percentage integers from stdout to update
-- a Yazi notification with live progress.
-- ─────────────────────────────────────────────────────────────────────────────
local function run_with_pipe_progress(cmd, notify_id, title_start)
	local handle = io.popen(cmd, "r")
	if not handle then
		ya.notify({ title = "Squish", content = "Failed to execute command", level = "error", timeout = 3.0 })
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
			ya.notify({
				title = "Squish",
				content = string.format("%s %d%%", title_start, pct),
				level = "info",
				timeout = 3.0,
				id = notify_id,
			})
			last_pct = pct
		end
	end

	local ok = handle:close()
	return ok and (last_pct == 100 or last_pct == -1)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Build (create squashfs archive)
-- ─────────────────────────────────────────────────────────────────────────────
local function run_build(dir_url)
	local id = "squish-build"
	ya.notify({ title = "Squish", content = "Starting build...", level = "info", timeout = 3.0, id = id })

	local target = dir_url .. ".sqsh"
	local cmd = string.format("squish --pipe '%s' -o '%s'", dir_url, target)
	local success = run_with_pipe_progress(cmd, id, "Building:")

	if success then
		ya.notify({ title = "Squish", content = "Built: " .. target, level = "info", timeout = 3.0, id = id })
		ya.emit("refresh", {})
	else
		ya.notify({ title = "Squish", content = "Build failed", level = "error", timeout = 3.0, id = id })
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Extract (extract squashfs archive)
-- If extract_path is nil, uses the unsquish default.
-- ─────────────────────────────────────────────────────────────────────────────
local function run_extract(file_url, extract_path)
	local id = "squish-extract"
	ya.notify({ title = "Squish", content = "Starting extraction...", level = "info", timeout = 3.0, id = id })

	local cmd
	if extract_path and extract_path ~= "" then
		cmd = string.format("unsquish --pipe -o '%s' '%s'", extract_path, file_url)
	else
		cmd = string.format("unsquish --pipe '%s'", file_url)
	end
	local success = run_with_pipe_progress(cmd, id, "Extracting:")

	if success then
		ya.notify({ title = "Squish", content = "Extracted successfully", level = "info", timeout = 3.0, id = id })
		ya.emit("refresh", {})
	else
		ya.notify({ title = "Squish", content = "Extraction failed", level = "error", timeout = 3.0, id = id })
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Mount
-- ─────────────────────────────────────────────────────────────────────────────
local function run_mount(file_url)
	local id = "squish-mount"
	ya.notify({ title = "Squish", content = "Mounting...", level = "info", timeout = 3.0, id = id })

	local cmd = string.format("squish -m '%s'", file_url)
	local result = os.execute(cmd .. " >/dev/null 2>&1")
	local success = (result == 0 or result == true)

	if success then
		ya.notify({ title = "Squish", content = "Mounted successfully", level = "info", timeout = 3.0, id = id })
	else
		ya.notify({ title = "Squish", content = "Mount failed", level = "error", timeout = 3.0, id = id })
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Unmount
-- ─────────────────────────────────────────────────────────────────────────────
local function run_unmount(file_url)
	local id = "squish-unmount"
	ya.notify({ title = "Squish", content = "Unmounting...", level = "info", timeout = 3.0, id = id })

	local cmd = string.format("squish -u '%s'", file_url)
	local result = os.execute(cmd .. " >/dev/null 2>&1")
	local success = (result == 0 or result == true)

	if success then
		ya.notify({ title = "Squish", content = "Unmounted successfully", level = "info", timeout = 3.0, id = id })
		ya.emit("refresh", {})
	else
		ya.notify({ title = "Squish", content = "Unmount failed", level = "error", timeout = 3.0, id = id })
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Entry
-- ─────────────────────────────────────────────────────────────────────────────
return {
	entry = function(self, job)
		local action = job.args and job.args[1]
		if not action then
			ya.notify({
				title = "Squish",
				content = "Usage: squish -- <build|extract|mount|unmount>",
				level = "error",
				timeout = 3.0,
			})
			return
		end

		local h = get_hovered()
		if not h then
			ya.notify({ title = "Squish", content = "No item selected", level = "error", timeout = 3.0 })
			return
		end

		if action == "build" then
			if not h.is_dir then
				ya.notify({
					title = "Squish",
					content = "Select a directory to compress",
					level = "error",
					timeout = 3.0,
				})
				return
			end
			run_build(h.url)
		elseif action == "extract" then
			-- Check if a second arg ("extract-to" path) was provided
			local extract_path = job.args[2]
			if extract_path then
				run_extract(h.url, extract_path)
			else
				run_extract(h.url)
			end
		elseif action == "extract-pick" then
			-- Interactive: prompt user for extraction directory
			local value, event = ya.input({
				title = "Extract to:",
				pos = { "center", w = 50 },
				value = tostring(h.url:gsub("%.[^.]+$", "")),
			})
			if event ~= 1 or not value or value == "" then
				return
			end
			run_extract(h.url, value)
		elseif action == "mount" then
			run_mount(h.url)
		elseif action == "unmount" then
			run_unmount(h.url)
		else
			ya.notify({ title = "Squish", content = "Unknown action: " .. action, level = "error", timeout = 3.0 })
		end
	end,
}
