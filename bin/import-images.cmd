@echo off
cd /d %~dp0
perl -w import-images.pl --archive
pause