@echo off
rem Esempio: Avvia-CLI.cmd -Profilo Ufficio -NomePC UFF-01
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0VMSetup.CLI.ps1" %*
