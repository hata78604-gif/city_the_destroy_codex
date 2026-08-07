@echo off
cd /d C:\rbxgame
echo === Updating sourcemap ===
rojo sourcemap default.project.json --output sourcemap.json
echo === Running static check ===
luau-lsp analyze --sourcemap=sourcemap.json --definitions=globalTypes.d.luau ServerScriptService ReplicatedStorage StarterPlayer > lint.txt 2>&1
type lint.txt
echo.
echo === Done ===
pause