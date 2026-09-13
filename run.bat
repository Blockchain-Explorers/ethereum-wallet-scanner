@echo off
:: ==============================================================================
:: run.bat - Ethereum Wallet Monitor Entrypoint
:: ==============================================================================
:: Purpose:
:: Convenient entrypoint for manual double-clicking, desktop shortcuts, or
:: the Windows Startup folder (shell:startup).
::
:: Execution Flow:
:: run.bat -> launch.vbs (silent windowless launcher) -> scan_wallet.ps1 (monitor)
:: ==============================================================================

cd /d "%~dp0"
wscript.exe "%~dp0launch.vbs"
