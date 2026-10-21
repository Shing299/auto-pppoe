# 双击运行。首次录入宽带账号密码并生成 pppoe-config.ini，之后直接拨号。
#
# 编码要求：本文件必须是 GBK 编码 + CRLF 换行，且不要 chcp。
#   UTF-8 代码页下 cmd 会把相邻的中文 echo 行解析错，报 'xxx' is not recognized。
# 配套的 pppoe-core.ps1 则必须是 UTF-8 带 BOM（PS 5.1 无 BOM 时按 GBK 解释）。

@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
set "CONFIG=%SCRIPT_DIR%pppoe-config.ini"
set "CORE=%SCRIPT_DIR%pppoe-core.ps1"

title PPPoE 自动拨号

rem ---------- 检查核心脚本 ----------
if not exist "%CORE%" (
    echo.
    echo [错误] 找不到核心脚本：
    echo        %CORE%
    echo        请确认 pppoe-core.ps1 与本脚本放在同一个文件夹。
    echo.
    pause
    exit /b 1
)

rem ---------- 是否已有配置 ----------
if not exist "%CONFIG%" goto :NEWCONFIG

set "CFG_OK="
for /f "usebackq tokens=1,* delims==" %%A in ("%CONFIG%") do (
    if /i "%%A"=="user" if not "%%B"=="" set "CFG_OK=1"
)
if not defined CFG_OK goto :NEWCONFIG
goto :DIAL

rem ---------- 首次运行：录入账号密码 ----------
:NEWCONFIG
cls
echo.
echo ============================================
echo              PPPoE 首次设置
echo ============================================
echo.
echo   需要录入宽带账号和密码，只需这一次。
echo   录入后会生成配置文件，以后双击直接拨号。
echo.
echo   账号示例：07751234567  或  07751234567@163.gd
echo   密码    ：运营商给的宽带密码
echo.

:ASKUSER
set "PPPOE_USER="
set /p "PPPOE_USER=请输入 PPPoE 账号："
if not defined PPPOE_USER (
    echo.
    echo [错误] 账号不能为空。
    goto :ASKUSER
)

:ASKPASS
set "PPPOE_PASS="
set /p "PPPOE_PASS=请输入 PPPoE 密码："
if not defined PPPOE_PASS (
    echo.
    echo [错误] 密码不能为空。
    goto :ASKPASS
)

> "%CONFIG%" echo user=%PPPOE_USER%
>>"%CONFIG%" echo pass=%PPPOE_PASS%

echo.
echo --------------------------------------------
echo [完成] 配置已保存到：
echo        %CONFIG%
echo        以后双击本脚本将直接拨号，不再询问。
echo --------------------------------------------
echo.
timeout /t 2 /nobreak >nul

rem ---------- 拨号 ----------
:DIAL
powershell -NoProfile -ExecutionPolicy Bypass -File "%CORE%" -ConfigPath "%CONFIG%"
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo 按任意键关闭窗口...
) else (
    echo 按任意键关闭窗口（可截图错误信息）...
)
pause >nul
exit /b %RC%