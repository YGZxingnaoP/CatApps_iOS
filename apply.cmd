@echo off
rem Windows 入口，实际逻辑在 apply.sh（需要 bash；Git for Windows 自带）
setlocal
set "HERE=%~dp0"

where bash >nul 2>nul
if errorlevel 1 (
    echo 找不到 bash。装 Git for Windows 后重试，或在 macOS 上直接执行 ./apply.sh
    exit /b 1
)

bash "%HERE%apply.sh" %*
exit /b %ERRORLEVEL%
