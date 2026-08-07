@echo off
chcp 65001 > nul
cd /d C:\rbxgame
echo === sourcemap を更新中 ===
rojo sourcemap default.project.json --output sourcemap.json
echo === 静的チェック実行中 ===
luau-lsp analyze --sourcemap=sourcemap.json --definitions=globalTypes.d.luau ServerScriptService ReplicatedStorage StarterPlayer > lint.txt 2>&1
type lint.txt
echo.
echo === 完了 ===
pause
