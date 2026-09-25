-- tests/harness.lua — minimal spec runner for the pure gate-route logic.
-- Usage: luajit harness.lua <spec files...>
-- Spec files call spec(name, fn) and assert_eq(actual, expected, msg).
local passed, failed = 0, 0

function spec(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		io.write("PASS  " .. name .. "\n")
	else
		failed = failed + 1
		io.write("FAIL  " .. name .. "  ->  " .. tostring(err) .. "\n")
	end
end

function assert_eq(actual, expected, msg)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s",
			msg or "assert_eq", tostring(expected), tostring(actual)), 2)
	end
end

for i = 1, #arg do
	local ok, err = pcall(dofile, arg[i])
	if not ok then
		failed = failed + 1
		io.write("FAIL  load " .. arg[i] .. "  ->  " .. tostring(err) .. "\n")
	end
end

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
