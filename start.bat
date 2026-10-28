@echo off
chcp 65001 >nul
cd /d "%~dp0"

rem ---- 定位虚拟环境的解释器（Windows 布局 Scripts\，MSYS2 布局 bin\）----
set "PY=.venv\Scripts\python.exe"
set "PYW=.venv\Scripts\pythonw.exe"
if exist ".venv\bin\python.exe" (
    set "PY=.venv\bin\python.exe"
    set "PYW=.venv\bin\pythonw.exe"
)

if not exist "%PY%" goto setup
goto deps

:setup
echo [MemoNest] 首次运行，正在创建虚拟环境…
python -m venv .venv
if errorlevel 1 goto fail
if exist ".venv\bin\python.exe" (
    set "PY=.venv\bin\python.exe"
    set "PYW=.venv\bin\pythonw.exe"
)

:deps
"%PY%" -c "import customtkinter" >nul 2>nul
if not errorlevel 1 goto run
echo [MemoNest] 正在安装界面依赖 customtkinter…
"%PY%" -m pip install --upgrade pip >nul 2>nul
"%PY%" -m pip install -r requirements.txt
if errorlevel 1 goto fail

:run
start "" "%PYW%" app.py
exit /b 0

:fail
echo.
echo [MemoNest] 启动失败。请确认已安装 Python 3.10+ 并加入 PATH，
echo             然后再次双击 start.bat。
pause
exit /b 1
