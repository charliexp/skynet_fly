@echo off
set skynet_fly_path=%1
set load_mods_name=%2

set lua=%skynet_fly_path%\skynet\3rd\lua\lua.exe
set script_path=%skynet_fly_path%\script\lua

if not exist "%lua%" (
    echo Lua executable not found at: %lua%
    exit /b 1
)

%lua% "%script_path%\write_config.lua" %skynet_fly_path% %load_mods_name%
%lua% "%script_path%\write_runsh.lua" %skynet_fly_path%