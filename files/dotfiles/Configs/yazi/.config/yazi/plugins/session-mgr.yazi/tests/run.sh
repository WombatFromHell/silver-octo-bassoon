#!/bin/sh
# session-mgr.yazi test suite — runs the plugin in-process with luajit (Lua 5.1).
# yazi embeds Lua 5.4; `nix run nixpkgs#lua5_4 -- tests/session-mgr-test.lua` also passes.
cd "$(dirname "$0")/.." && luajit tests/session-mgr-test.lua
