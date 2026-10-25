-- Run directly with osascript from the already-authorized controlling app.
-- Never launches or resizes a game. Input additionally requires observed ps lstart.
on run argv
    if (count of argv) is less than 2 then error "PID and action required"
    set targetPID to (item 1 of argv) as integer
    set requestedAction to item 2 of argv
    if requestedAction is not in {"state", "return", "back", "equipment"} then error "Unsupported action"
    set actualStart to do shell script "/bin/ps -p " & targetPID & " -o lstart= | /usr/bin/sed 's/[[:space:]]*$//'"
    if requestedAction is not "state" then
        if (count of argv) is not 3 then error "Observed process start required for input"
        if actualStart is not (item 3 of argv) then error "PID was reused; observe again"
    end if
    tell application "System Events"
        set gp to first application process whose unix id is targetPID
        set windowTitles to name of every window of gp
        if (count of windowTitles) is not 1 then error "Expected exactly one game window"
        if (item 1 of windowTitles) does not start with "StellarBlade" then error "Unexpected title"
        if requestedAction is not "state" then
            set frontmost of gp to true
            if requestedAction is "return" then tell gp to key code 36
            if requestedAction is "back" then tell gp to key code 53
            if requestedAction is "equipment" then tell gp to key code 48
        end if
        return {unix id of gp, actualStart, windowTitles, position of window 1 of gp, size of window 1 of gp}
    end tell
end run
