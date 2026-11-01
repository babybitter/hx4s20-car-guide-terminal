@echo off
chcp 65001 >nul
cd /d "%~dp0"
if exist "%~dp0dist\HX4S20_Studio\HX4S20_Studio.exe" (
  start "" "%~dp0dist\HX4S20_Studio\HX4S20_Studio.exe" %*
  exit /b
)
if exist "%~dp0.venv\Scripts\pythonw.exe" (
  start "" "%~dp0.venv\Scripts\pythonw.exe" "%~dp0main.py" %*
  exit /b
)
echo 未找到 EXE 或项目独立 Python 环境。
echo 请在本目录运行以下命令完成源码环境准备：
echo python -m venv .venv
echo .venv\Scripts\python.exe -m pip install -r requirements.txt
pause
