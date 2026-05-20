@echo off
chcp 65001 >nul
set "SCRIPT=%USERPROFILE%\Desktop\BridgeTools\upload_bridge.ps1"
set "TEMP_SCRIPT=%TEMP%\AI_Bridge_upload_runner.ps1"

if not exist "%SCRIPT%" (
    echo 未找到上传脚本: %SCRIPT%
    pause
    exit /b 1
)

copy /Y "%SCRIPT%" "%TEMP_SCRIPT%" >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%TEMP_SCRIPT%"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
    echo 上传失败，退出码 %EXIT_CODE%
) else (
    echo 上传完成。
)

pause
exit /b %EXIT_CODE%