@echo off
set RESTART=2
	
:restart
	title hub
	cls
	call ruby3 rq_hub.rb
	if %errorlevel%==%RESTART% goto :restart
	title [X] hub
	echo.
	echo [Restart?]
	pause
goto :restart
