@echo off
chcp 65001 >nul
set "SCRIPT=%USERPROFILE%\Desktop\BridgeTools\update_bridge.ps1"
set "TEMP_SCRIPT=%TEMP%\AI_Bridge_update_runner.ps1"

if not exist "%SCRIPT%" (
    echo 未找到更新脚本: %SCRIPT%
    echo 请先确认桌面上存在 BridgeTools\update_bridge.ps1
    pause
    exit /b 1
)

copy /Y "%SCRIPT%" "%TEMP_SCRIPT%" >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%TEMP_SCRIPT%"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
    echo 更新失败，退出码 %EXIT_CODE%
) else (
    echo 更新完成。
)

pause
exit /b %EXIT_CODE%