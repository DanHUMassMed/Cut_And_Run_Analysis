property helperPath : ""
property appPath : ""
property stopServerOnQuit : true

on ensurePaths()
	set p to POSIX path of (path to me)
	if p ends with "/" then
		set p to text 1 thru -2 of p
	end if
	set appPath to p
	set helperPath to p & "/Contents/Resources/app_launcher.sh"
end ensurePaths

on showRunningDialog(serverUrl, workspacePath, pipelineState, logFile)
	set statusSummary to "Workspace: " & workspacePath & return & "Pipeline: " & pipelineState & return & "URL: " & serverUrl
	try
		set dialogResult to display dialog "CUT&RUN Pipeline Control Center is running." & return & return & statusSummary buttons {"Stop Server", "View Logs", "Open Browser"} default button "Open Browser" with title "CUT&RUN Control Center"
		set chosenButton to button returned of dialogResult
	on error number -128
		return
	end try

	if chosenButton is "Open Browser" then
		do shell script "open " & quoted form of serverUrl
	else if chosenButton is "View Logs" then
		try
			do shell script "open -a Console " & quoted form of logFile
		on error
			do shell script "open -t " & quoted form of logFile
		end try
	else if chosenButton is "Stop Server" then
		set stopServerOnQuit to true
		quit
	end if
end showRunningDialog

on run
	my ensurePaths()
	set stopServerOnQuit to true
	set infoLine to ""

	try
		set infoLine to do shell script "/usr/bin/env bash " & quoted form of helperPath & " " & quoted form of appPath & " check"
	on error errMsg number errNum
		if errNum is 42 or errMsg contains "MISSING_PIPELINE_DIR" then
			try
				set pickedFolder to POSIX path of (choose folder with prompt "Locate the Cut_And_Run_Analysis pipeline folder (containing manage.sh):")
				if pickedFolder ends with "/" then
					set pickedFolder to text 1 thru -2 of pickedFolder
				end if
				do shell script "/usr/bin/env bash " & quoted form of helperPath & " " & quoted form of appPath & " save-pipeline " & quoted form of pickedFolder
				set infoLine to do shell script "/usr/bin/env bash " & quoted form of helperPath & " " & quoted form of appPath & " check"
			on error pickErr number pickNum
				if pickNum is not -128 then
					display alert "CUT&RUN Control Center Error" message pickErr as critical
				end if
				set stopServerOnQuit to false
				quit
				return
			end try
		else
			display alert "CUT&RUN Control Center Error" message errMsg as critical
			set stopServerOnQuit to false
			quit
			return
		end if
	end try

	set oldDelims to AppleScript's text item delimiters
	set AppleScript's text item delimiters to "|"
	set infoParts to text items of infoLine
	set AppleScript's text item delimiters to oldDelims

	set serverState to item 1 of infoParts
	set serverUrl to item 2 of infoParts
	set workspacePath to item 3 of infoParts
	set pipelineState to item 4 of infoParts
	set logFile to item 5 of infoParts

	if serverState is "stopped" then
		try
			do shell script "/usr/bin/env bash " & quoted form of helperPath & " " & quoted form of appPath & " start"
		on error errMsg
			display alert "CUT&RUN Control Center Failed to Start" message errMsg as critical
			set stopServerOnQuit to false
			quit
		end try
	else
		my showRunningDialog(serverUrl, workspacePath, pipelineState, logFile)
	end if
end run

on reopen
	my ensurePaths()
	try
		set infoLine to do shell script "/usr/bin/env bash " & quoted form of helperPath & " " & quoted form of appPath & " check"
		set oldDelims to AppleScript's text item delimiters
		set AppleScript's text item delimiters to "|"
		set infoParts to text items of infoLine
		set AppleScript's text item delimiters to oldDelims
		if (item 1 of infoParts) is "running" then
			my showRunningDialog(item 2 of infoParts, item 3 of infoParts, item 4 of infoParts, item 5 of infoParts)
		else
			do shell script "/usr/bin/env bash " & quoted form of helperPath & " " & quoted form of appPath & " start"
		end if
	on error errMsg
		display alert "CUT&RUN Control Center Error" message errMsg as critical
	end try
end reopen

on idle
	try
		my ensurePaths()
		set infoLine to do shell script "/usr/bin/env bash " & quoted form of helperPath & " " & quoted form of appPath & " check"
		if infoLine starts with "stopped|" then
			set stopServerOnQuit to false
			quit
		end if
	end try
	return 3
end idle

on quit
	if stopServerOnQuit then
		try
			my ensurePaths()
			do shell script "/usr/bin/env bash " & quoted form of helperPath & " " & quoted form of appPath & " stop"
		end try
	end if
	continue quit
end quit
