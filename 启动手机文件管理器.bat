@echo off
chcp 65001 >nul
cd /d "%~dp0"
start "" powershell -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "%~dp0MtpAdbFileManager.ps1"
