Output "/tmp/harnt-demo/raw.mp4"
Require nvim
Set Shell "bash"
Set FontSize 16
Set Width 1200
Set Height 720
Set Padding 16
Set Theme "Catppuccin Mocha"

Hide
Type "cd /Users/pieterpel/home/private-projects/harnt.nvim" Enter
Type "clear" Enter
Show

Type "nvim -u scripts/demo-gif-init.lua" Enter
Sleep 3s
Type ":Harnt open antigravity" Enter
Sleep 24s
