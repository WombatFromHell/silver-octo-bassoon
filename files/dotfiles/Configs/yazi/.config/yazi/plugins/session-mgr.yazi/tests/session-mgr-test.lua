-- Tests for session-mgr.yazi user-facing behaviour: startup restore, save, load,
-- delete, chooser. Run: luajit tests/session-mgr-test.lua (from the plugin dir).
local H = loadfile("./tests/harness.lua")()

local a, b

local function count(list, value)
	local n = 0
	for _, v in ipairs(list) do
		if v == value then n = n + 1 end
	end
	return n
end

-- Fresh store + pinned session dir, optional saved session keyed on the invoked dir,
-- then plugin startup (H.new's setup sees an empty store; setup here does the restore).
local function startup(fixture_cwd, saved_tabs, active_idx)
	H.reset()
	local inv = H.canonical(fixture_cwd)
	local M, state = H.new({ cwd = inv })
	if saved_tabs then
		H.write_session(inv, saved_tabs, active_idx or 1)
	end
	M.setup({}, {})
	return state, inv
end

-- ---- startup restore -----------------------------------------------------
H.reset()
a, b = H.canonical("/tmp/session-mgr-test/a"), H.canonical("/tmp/session-mgr-test/b")

-- Session tab 1 is another dir: the invoked dir keeps its own tab.
local state, inv = startup("/tmp/session-mgr-test/a", { b }, 1)
assert(count(H.tab_dirs(state), inv) == 1, "invoked dir " .. inv .. " has no tab")
assert(state.emits[#state.emits].name == "tab_create", "invoked dir is not the active tab")
assert(H.arg(state, "cd")[1] == b, "saved tab 1 was not restored")

-- The CLI argument is yazi's startup dir: the session is keyed on the shell cwd, and
-- the argument still gets its own tab. (fs.cwd() at setup is the shell cwd, not the arg.)
local c = H.canonical("/tmp/session-mgr-test/c")
H.reset()
local arg_M, arg_state = H.new({ cwd = a, argv = { "yazi", "/tmp/session-mgr-test/c" } })
H.write_session(a, { b, a }, 1)
arg_M.setup({}, {})
assert(count(H.tab_dirs(arg_state), c) == 1, "invoked argument " .. c .. " has no tab")
assert(arg_state.emits[#arg_state.emits].name == "tab_create", "invoked argument is not the active tab")
assert(arg_state.emits[#arg_state.emits - 1].name == "tab_switch"
	and arg_state.emits[#arg_state.emits - 1].arg[1] == 1, "extra tab is not appended after the session tabs")
assert(H.arg(arg_state, "cd")[1] == b, "saved tab 1 was not restored")
assert(count(H.tab_dirs(arg_state), a) == 1, "saved tabs duplicated")

-- Flags before the positional argument (yy passes --cwd-file=) do not hide the dir.
H.reset()
local flag_M, flag_state = H.new({ cwd = a, argv = { "yazi", "--cwd-file=/tmp/x", "/tmp/session-mgr-test/c" } })
H.write_session(a, { b, a }, 1)
flag_M.setup({}, {})
assert(count(H.tab_dirs(flag_state), c) == 1, "argument after a flag has no tab")

-- Argument already among the saved tabs: no duplicate.
H.reset()
local dup_M, dup_state = H.new({ cwd = a, argv = { "yazi", "/tmp/session-mgr-test/b" } })
H.write_session(a, { b, a }, 2)
dup_M.setup({}, {})
assert(count(H.tab_dirs(dup_state), b) == 1, "duplicate tab for an argument already saved")

-- An argument that is not a real path is ignored; startup falls back to the shell cwd.
H.reset()
local bad_M, bad_state = H.new({ cwd = a, argv = { "yazi", "/tmp/session-mgr-test/nope" } })
H.write_session(a, { b, a }, 2)
bad_M.setup({}, {})
assert(count(H.tab_dirs(bad_state), "/tmp/session-mgr-test/nope") == 0, "nonexistent argument created a tab")
assert(count(H.tab_dirs(bad_state), a) == 1, "bad argument did not fall back to the shell cwd")

-- A file argument opens its parent dir in yazi, so it must not create a tab.
H.reset()
local file_M, file_state = H.new({ cwd = a, argv = { "yazi", "/tmp/session-mgr-test/c/README.md" } })
H.write_session(a, { b, a }, 2)
file_M.setup({}, {})
assert(count(H.tab_dirs(file_state), H.canonical("/tmp/session-mgr-test/c/README.md")) == 0, "file argument created a tab")
assert(count(H.tab_dirs(file_state), a) == 1, "file argument did not fall back to the shell cwd")

-- Invoked dir already saved (raw or symlinked): exactly one tab for it.
state, inv = startup("/tmp/session-mgr-test/a", { "/tmp/session-mgr-test/a", b }, 1)
assert(count(H.tab_dirs(state), inv) == 1, "duplicate tab for an already-saved dir")
state, inv = startup("/tmp/session-mgr-test/a", { "/tmp/session-mgr-test/link" }, 1)
assert(count(H.tab_dirs(state), inv) == 1, "symlinked tab produced a duplicate tab")

-- Fallback scan: file named for a symlinked path, invoked by its canonical path.
H.reset()
local fb_M, fb_state = H.new({ cwd = a })
H.write_session(b, { "/tmp/session-mgr-test/link" }, 1, "/tmp/session-mgr-test/link")
fb_M.setup({}, {})
assert(H.arg(fb_state, "cd")[1] == "/tmp/session-mgr-test/link", "fallback match did not restore")
assert(count(H.tab_dirs(fb_state), a) == 1, "fallback match duplicated the invoked dir")

-- Saved prefs are re-applied to every restored tab.
state, inv = startup("/tmp/session-mgr-test/a", { "/tmp/session-mgr-test/link", b }, 2)
local sort = H.emitted(state, "sort")
assert(#sort == 2 and sort[1].reverse == true and sort[2].reverse == true, "saved sort order not applied to every restored tab")
assert(sort[1].by == "natural", "saved sort method not applied")
assert(H.arg(state, "hidden")[1] == "show", "saved hidden setting not applied")
assert(H.arg(state, "linemode")[1] == "ino", "saved linemode not applied")
assert(count(H.tab_dirs(state), inv) == 1, "restored tabs duplicated the invoked dir")

-- No session for the invoked dir: nothing restored, startup tab untouched.
state = startup("/tmp/session-mgr-test/b", nil)
assert(#state.emits == 0, "expected no emits when no session matches")

-- A corrupt session file restores nothing and does not crash startup.
H.reset()
local corrupt_M, corrupt_state = H.new({ cwd = a })
local corrupt = assert(io.open(H.session_path(a), "w"))
corrupt:write('return { ["cwd"] = "nope" [')
corrupt:close()
corrupt_M.setup({}, {})
assert(#corrupt_state.emits == 0, "corrupt session restored something")

-- ---- save ----------------------------------------------------------------
local function save(args, tabs, idx, cwd)
	H.reset()
	local M, st = H.new({ tabs = tabs, idx = idx, cwd = cwd })
	M:entry({ args = args })
	return st
end

state = save({ "save" }, { b, a }, 2, a)
assert(#H.emitted(state, "quit") == 0, "plain save quit yazi")
local saved = loadfile(H.session_path(a))()
assert(saved.cwd == a, "session not keyed on the active tab cwd")
assert(#saved.tabs == 2 and saved.tabs[1].cwd == b and saved.tabs[2].cwd == a, "tab order lost")
assert(saved.active_idx == 2, "active tab index lost")
assert(saved.tabs[1].sort_reverse == true, "tab preferences lost")
assert(saved.tabs[1].show_hidden == true, "hidden preference lost")

state = save({ "save-and-quit" }, { a }, 1, a)
assert(#H.emitted(state, "quit") == 1, "save-and-quit did not quit")
assert(state.notices[1]:match("Session saved") ~= nil, "no save notification")

-- ---- load ----------------------------------------------------------------
local name = H.session_path(a):match("([^/]+)%.lua$")

local function load(arg, open_tabs)
	H.reset()
	local M, st = H.new({ cwd = a, tabs = open_tabs or { b } })
	H.write_session(a, { b, a }, 2)
	M:load(arg)
	return st
end

state = load(name, { b })
assert(#H.emitted(state, "tab_close") == 1, "open tab was not closed")
assert(H.arg(state, "cd")[1] == b, "saved tab 1 not restored")
assert(#H.emitted(state, "tab_create") == 1, "saved tab 2 not restored")
assert(#H.emitted(state, "tab_switch") == 2 and H.emitted(state, "tab_switch")[2][1] == 1, "active tab index not restored")
assert(#H.emitted(state, "sort") == 2 and H.emitted(state, "sort")[2].reverse == true, "saved sort order not applied to the restored tabs")
assert(state.notices[1]:match("Session loaded") ~= nil, "no load notification")

-- A path argument, including a symlinked variant, resolves through the fallback scan.
state = load(H.canonical("/tmp/session-mgr-test/link"), { b })
assert(H.arg(state, "cd")[1] == b, "path load did not find the session")
assert(count(H.tab_dirs(state), a) == 1, "mid-session load added a duplicate tab")

state = load("nope", { b })
assert(#state.emits == 0, "missing session restored something")
assert(state.notices[1]:match("No session found") ~= nil, "missing session was silent")

-- ---- delete --------------------------------------------------------------
H.reset()
local M, del_state = H.new({ cwd = a })
H.write_session(a, { b }, 1)
H.write_session(b, { a }, 1)
M:delete(name)
assert(io.open(H.session_path(a), "r") == nil, "session file not removed")
assert(io.open(H.session_path(b), "r") ~= nil, "unrelated session was removed")
assert(del_state.notices[1]:match("Session deleted") ~= nil, "delete was silent")

M, del_state = H.new({ cwd = a })
M:delete("nope")
assert(io.open(H.session_path(b), "r") ~= nil, "deleting a missing session removed something")
assert(del_state.notices[1]:match("Session not found") ~= nil, "missing delete was silent")

-- ---- chooser -------------------------------------------------------------
local function chooser(output, code, sessions)
	H.reset()
	local M, st = H.new({ cwd = a, tabs = { a }, fzf_output = output, fzf_code = code })
	for _, s in ipairs(sessions) do
		H.write_session(s.cwd, s.tabs, s.active_idx)
	end
	M:chooser()
	return st
end

state = chooser("enter\r1\r", 0, { { cwd = a, tabs = { b }, active_idx = 1 } })
assert(state.permits == 0, "chooser left the UI hidden")
assert(H.arg(state, "cd")[1] == b, "chooser restored the wrong session")

state = chooser("ctrl-d\r1\r2\r", 0, { { cwd = a, tabs = { b }, active_idx = 1 }, { cwd = b, tabs = { a }, active_idx = 1 } })
assert(io.open(H.session_path(a), "r") == nil and io.open(H.session_path(b), "r") == nil, "ctrl-d deleted one session only")
assert(state.notices[#state.notices]:match("2 session%(s%) deleted") ~= nil, "no delete count")
assert(state.permits == 0, "chooser left the UI hidden after delete")

-- Esc (exit 130): nothing restored, nothing deleted, UI unhidden, even with a stray line.
state = chooser("1\r", 130, { { cwd = a, tabs = { b }, active_idx = 1 }, { cwd = b, tabs = { a }, active_idx = 1 } })
assert(#state.emits == 0, "cancelled chooser restored something")
assert(io.open(H.session_path(a), "r") ~= nil, "cancelled chooser deleted a session")
assert(state.permits == 0, "cancelled chooser left the UI hidden")

print("OK: session-mgr startup/save/load/delete/chooser")
