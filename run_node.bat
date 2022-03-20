@echo off
set RESTART=2
	
:restart
	title node
	cls
	call ruby3 rq_node.rb
	if %errorlevel%==%RESTART% goto :restart
	title [X] node
	echo.
	echo [Restart?]
	pause
goto :restart