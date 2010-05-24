@echo off
cd /d %~dp0
call C:\Strawberry\path.cmd
perl -w import-images.pl --archive --target \\aliens\corion\backup\Photos
pause