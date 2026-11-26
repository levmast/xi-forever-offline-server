@echo off
setlocal enabledelayedexpansion
set VSROOT=C:\Program Files\Microsoft Visual Studio\18\Community
for /d %%D in ("%VSROOT%\VC\Tools\MSVC\*") do set MSVC=%%D
set SDKROOT=C:\Program Files (x86)\Windows Kits\10
for /d %%D in ("%SDKROOT%\Include\10.0.*") do set SDKVER=%%~nxD
set INCLUDE=%MSVC%\include;%SDKROOT%\Include\%SDKVER%\ucrt;%SDKROOT%\Include\%SDKVER%\um;%SDKROOT%\Include\%SDKVER%\shared;%SDKROOT%\Include\%SDKVER%\winrt;%SDKROOT%\Include\%SDKVER%\cppwinrt
set LIB=%MSVC%\lib\x64;%SDKROOT%\Lib\%SDKVER%\ucrt\x64;%SDKROOT%\Lib\%SDKVER%\um\x64
echo MSVC=%MSVC%
echo SDK=%SDKVER%
rem Ninja is a single-config generator, so --config was ignored and the Release link
rem shipped no PDB, which left crash tombstones full of ?? frames. CMake already
rem compiles with /Zi (CMAKE_MSVC_DEBUG_INFORMATION_FORMAT=ProgramDatabase), so only
rem the link needs /DEBUG. Jobs stay capped: several PCH compiles in parallel exhaust
rem the commit charge (C3859 / C1076 compiler limit: internal heap limit reached).
cmake -S "C:\ffxi-local\server" -B "C:\ffxi-local\server\build" -DCMAKE_CXX_FLAGS_RELEASE="/O2 /Ob2 /DNDEBUG" -DCMAKE_EXE_LINKER_FLAGS_RELEASE="/INCREMENTAL:NO /DEBUG"
if errorlevel 1 exit /b 1
cmake --build "C:\ffxi-local\server\build" --target xi_connect -- -j 4
if errorlevel 1 exit /b 1

echo Built xi_connect.exe (the login server)
