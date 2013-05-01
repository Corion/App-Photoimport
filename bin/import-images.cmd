@echo off
cd /d %~dp0
call C:\strawberry-perl-5.16.3.1-x64\path.cmd
perl -w import-images.pl --archive --target \\aliens\corion\backup\Photos
pause