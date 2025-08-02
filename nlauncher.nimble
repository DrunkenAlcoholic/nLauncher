version       = "0.3.0"
author        = "DrunkenAlcoholic"
description   = "A simple, fast, and highly configurable application launcher for X11"
license       = "MIT"
srcDir        = "src"
bin           = @["nlauncher"]

# — Dependencies ——————————————————————————————————————————————————————
requires "nim >= 2.2.0"
requires "parsetoml"
requires "x11"

# Build tasks
task release, "Build the application with release flags":
  #mkDir("bin")
  exec "nim c -d:release -d:danger --opt:size -o:./bin/nlauncher src/nlauncher.nim"
  

task fast, "Build with speed optimizations (safer than danger)":
  mkDir("bin")
  exec "nim c -d:release --opt:speed -o:./bin/nlauncher src/nlauncher.nim"

task debug, "Build the application in debug mode":
  exec "nim c -o:./bin/nlauncher src/nlauncher.nim"

task clear, "Clean build artifacts":
  rmFile("bin/nlauncher")
  rmFile("nlauncher")  # In case it's left in root
