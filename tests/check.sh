#!/usr/bin/env bash
#
# Prueft das Addon, ohne das Spiel zu starten:
#   1. luacheck: Syntax und Zugriffe auf nicht vorhandene Namen (falls installiert)
#   2. luac -p:  Syntax jeder Datei
#   3. die Tests in tests/run.lua unter Lua 5.1 (der Version, die WoW 3.3.5a benutzt)
#
#   tests/check.sh
#
# Benoetigt: lua5.1, optional luacheck (luarocks install luacheck).

cd "$(dirname "$0")/.." || exit 2
FAILED=0

LUA=$(command -v lua5.1 || command -v lua)
if [ -z "$LUA" ]; then echo "lua5.1 nicht gefunden" >&2; exit 2; fi

echo "== 1/3 luacheck"
if command -v luacheck >/dev/null 2>&1; then
    luacheck --no-color --formatter plain . || FAILED=1
else
    echo "   uebersprungen (luacheck nicht installiert)"
fi

echo "== 2/3 Syntax"
LUAC=$(command -v luac5.1 || command -v luac)
for f in *.lua tests/*.lua; do
    if [ -n "$LUAC" ]; then
        "$LUAC" -p "$f" || FAILED=1
    else
        "$LUA" -e "assert(loadfile('$f'))" || FAILED=1
    fi
done
echo "   ok"

echo "== 3/3 Tests"
"$LUA" tests/run.lua | grep -v '^- '
[ "${PIPESTATUS[0]}" -eq 0 ] || FAILED=1

echo
if [ $FAILED -ne 0 ]; then echo "FEHLGESCHLAGEN"; exit 1; fi
echo "alles in Ordnung"
