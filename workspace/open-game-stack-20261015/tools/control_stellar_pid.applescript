-- Run directly with osascript from the already-authorized controlling app.
-- Never launches or resizes a game. Input additionally requires observed ps lstart.
on run argv
    if (count of argv) is less than 2 then error "PID and action required"
    set targetPID to (item 1 of argv) as integer
    set requestedAction to item 2 of argv
    if requestedAction is not in {"state", "return", "back", "equipment", "attack"} then error "Unsupported action"
    set actualStart to do shell script "/bin/ps -p " & targetPID & " -o lstart= | /usr/bin/sed 's/[[:space:]]*$//'"
    if requestedAction is not "state" then
        if (count of argv) is not 3 then error "Observed process start required for input"
        if actualStart is not (item 3 of argv) then error "PID was reused; observe again"
    end if
    tell application "System Events"
        set gp to first application process whose unix id is targetPID
        -- Fullscreen windows can be absent from AX while their Space is not active.
        -- Activate this already identity-checked process before validating input.
        if requestedAction is not "state" then
            set frontmost of gp to true
            repeat 30 times
                if (count of windows of gp) is 1 then exit repeat
                delay 0.1
            end repeat
        end if
        set windowTitles to name of every window of gp
        if (count of windowTitles) is not 1 then error "Expected exactly one game window; fullscreen Space may not yet be available"
        if (item 1 of windowTitles) does not start with "StellarBlade" then error "Unexpected title"
        if requestedAction is not "state" then
            set frontmost of gp to true
            if requestedAction is "return" then tell gp to key code 36
            if requestedAction is "back" then tell gp to key code 53
            if requestedAction is "equipment" then tell gp to key code 53
            if requestedAction is "attack" then
                set gamePosition to position of window 1 of gp
                set gameSize to size of window 1 of gp
                set targetX to (item 1 of gamePosition) + ((item 1 of gameSize) div 2)
                set targetY to (item 2 of gamePosition) + ((item 2 of gameSize) div 2)
                click at {targetX, targetY}
            end if
        end if
        return {unix id of gp, actualStart, windowTitles, position of window 1 of gp, size of window 1 of gp}
    end tell
end run
