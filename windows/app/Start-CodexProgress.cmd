@echo off
start "Codex Progress" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File "%~dp0CodexProgress.ps1" "%~dp0..\..\task-progress-v2.json"
