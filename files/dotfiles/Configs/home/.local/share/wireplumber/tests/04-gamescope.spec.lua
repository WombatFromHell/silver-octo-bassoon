-- tests/04-gamescope.spec.lua — S5: gamescope env forces the gate open.
-- compute_gate_open(is_gamescope, sentinel_present) → boolean
-- The gamescope session is itself the "gate open" signal; the sentinel is the
-- escape-hatch for non-gamescope environments.
local gate = dofile("../scripts/gate-route.lua")

spec("gamescope mode: gate open even without sentinel", function()
	assert_eq(gate.compute_gate_open(true, false), true)
end)

spec("gamescope mode: gate open with sentinel", function()
	assert_eq(gate.compute_gate_open(true, true), true)
end)

spec("non-gamescope: gate closed without sentinel", function()
	assert_eq(gate.compute_gate_open(false, false), false)
end)

spec("non-gamescope: gate open with sentinel (escape-hatch)", function()
	assert_eq(gate.compute_gate_open(false, true), true)
end)
