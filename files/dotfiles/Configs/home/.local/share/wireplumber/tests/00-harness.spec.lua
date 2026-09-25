-- tests/00-harness.spec.lua — harness self-test (S0).
spec("harness runs a passing test", function()
	assert_eq(1, 1)
end)
