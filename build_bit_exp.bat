@echo off
REM ============================================================
REM  build_bit_exp.bat - one-click bitstream build for exp N
REM
REM  Usage (double click, or from CMD):
REM      build_bit_exp.bat 6
REM
REM  If no argument is given, EXP defaults to 6.
REM  Before running: run "bash .workbuddy/sim/switch_exp.sh <N>"
REM  to install the right image, and CLOSE the project in Vivado GUI.
REM  Takes about 13 minutes. Do not close the window.
REM ============================================================

set EXP=%1
if "%EXP%"=="" set EXP=6

set ROOT=D:\Courses\Computer_organization_design\Main_project_1.1
set VIVADO=D:\Xilinx\Vivado\2023.2\bin\vivado.bat

echo.
echo ===== Building bitstream for EXP%EXP% =====
echo Project : %ROOT%
echo Vivado  : %VIVADO%
echo Started : %date% %time%
echo.

cd /d "%ROOT%"

if not exist "%VIVADO%" (
    echo [ERROR] Vivado not found at %VIVADO%
    pause
    exit /b 1
)

call "%VIVADO%" -mode batch -source ".workbuddy\sim\rebuild_bit_expN.tcl" -tclargs %EXP%

echo.
echo ===== Finished at %time% =====
echo Output bit : %ROOT%\looongson_remote_top_EXP%EXP%.bit
echo             %ROOT%\.workbuddy\sim\exp%EXP%\looongson_remote_top_EXP%EXP%.bit
echo Timing rpt : %ROOT%\.workbuddy\sim\timing_exp%EXP%.rpt
echo.
pause
