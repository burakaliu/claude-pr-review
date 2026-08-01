' Run one pass of the review daemon with no visible window.
'
' Task Scheduler has no setting that reliably suppresses a console window, so
' pointing the task straight at bash.exe flashes one on screen every poll
' interval, all day. wscript.exe running this file shows nothing at all.
'
' Both paths are passed in by install.ps1 rather than discovered here, so this
' file holds nothing machine specific.
'
' Usage:
'   wscript.exe run-daemon.vbs "<bash.exe>" "<review-daemon.sh>" [daemon args...]

Option Explicit

Dim args, bashExe, daemon, cmd, i, shell, rc

Set args = WScript.Arguments

If args.Count < 2 Then
  WScript.Echo "usage: run-daemon.vbs <bash.exe> <review-daemon.sh> [args...]"
  WScript.Quit 2
End If

bashExe = args(0)
daemon = args(1)

' -l runs it as a login shell. Without that, /usr/bin is missing from PATH and
' the daemon cannot find perl, sed, or mktemp.
cmd = """" & bashExe & """ -l """ & daemon & """"

For i = 2 To args.Count - 1
  cmd = cmd & " """ & args(i) & """"
Next

Set shell = CreateObject("WScript.Shell")

' 0 hides the window. True waits for the pass to finish, so Task Scheduler
' sees the real duration and its IgnoreNew policy can suppress an overlapping
' run. The daemon takes its own lock as well, so overlap is harmless either way.
rc = shell.Run(cmd, 0, True)

WScript.Quit rc
