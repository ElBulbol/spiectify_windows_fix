@echo off
rem Double-click launcher. Add -DryRun to preview without changing anything.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Spotify-Spicetify-Setup.ps1" %*
