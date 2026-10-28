@echo off
setlocal
cd /d "%~dp0"

rem ---- Locate the virtualenv interpreter (Windows Scripts\ or POSIX bin\) ----
set "PY=.venv\Scripts\python.exe"
set "PYW=.venv\Scripts\pythonw.exe"
if exist ".venv\bin\python.exe" (
    set "PY=.venv\bin\python.exe"
    set "PYW=.venv\bin\python.exe"
)

if not exist "%PY%" goto setup
if not exist "%PYW%" set "PYW=%PY%"
goto deps

:setup
echo [MemoNest] First run: creating virtual environment...
where py >nul 2>nul
if errorlevel 1 (
    python -m venv .venv
) else (
    py -3 -m venv .venv
)
if errorlevel 1 goto fail
if exist ".venv\Scripts\python.exe" (
    set "PY=.venv\Scripts\python.exe"
    set "PYW=.venv\Scripts\pythonw.exe"
)
if exist ".venv\bin\python.exe" (
    set "PY=.venv\bin\python.exe"
    set "PYW=.venv\bin\python.exe"
)
if not exist "%PYW%" set "PYW=%PY%"

:deps
"%PY%" -c "import customtkinter, cryptography" >nul 2>nul
if not errorlevel 1 goto run
echo [MemoNest] Installing dependencies...
"%PY%" -m pip install --upgrade pip >nul 2>nul
"%PY%" -m pip install -r requirements.txt
if errorlevel 1 goto fail

:run
rem Start with pythonw so no console window stays open
start "" "%PYW%" app.py
exit /b 0

:fail
echo.
echo [MemoNest] Startup failed. Install Python 3.10+ (with tcl/tk),
echo            make sure "py -3" or "python" works, then run start.bat again.
pause
exit /b 1
