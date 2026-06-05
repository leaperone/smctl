Output smctl-demo.gif

Set FontSize 16
Set Width 900
Set Height 600
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms
Set Padding 16

Type "smctl sensors"
Sleep 500ms
Enter
Sleep 3.5s

Type "clear"
Enter
Type "smctl fan status"
Sleep 500ms
Enter
Sleep 2.5s

Type "smctl fan set 2500"
Sleep 500ms
Enter
Sleep 4s

Type "smctl fan status"
Sleep 500ms
Enter
Sleep 3s

Type "smctl battery maintain 70-80"
Sleep 500ms
Enter
Sleep 2s

Type "smctl fan auto && smctl battery maintain stop"
Sleep 500ms
Enter
Sleep 3s
