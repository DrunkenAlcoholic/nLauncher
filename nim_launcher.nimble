version       = "1.0.0"
author        = "DrunkenAlcoholic"
description   = "A simple, fast, and highly configurable application launcher for X11"
license       = "GPL v3" 
srcDir        = "src" 

# Dependencies
requires "nim >= 2.0.0"
requires "x11"


bin = @["nim_launcher"]

# Custom tasks are still great for things like linting.
task lint, "Lint all *.nim files":
  # A more precise glob pattern for your source files
  exec "nimpretty --indent:2 --maxLineLen:106 scr/**/*.nim"
