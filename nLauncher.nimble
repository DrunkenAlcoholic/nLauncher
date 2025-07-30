version       = "0.3.0"
author        = "DrunkenAlcoholic"
description   = "A simple, fast, and highly configurable application launcher for X11"
license       = "MIT"
srcDir        = "src"
bin           = @["nLauncher"]

# — Dependencies ——————————————————————————————————————————————————————
requires "nim >= 2.2.0"
requires "parsetoml"
requires "x11"

# — Default build ——————————————————————————————————————————————————————
# `nimble build` will use the `build` task if present, otherwise `nim c srcDir/*.nim`
task build, "Compile nLauncher in release mode with optimizations":
  exec "nim c --hints:off --opt:speed --opt:l:none -d:release -o:nLauncher src/nLauncher.nim"

# — Development helpers ——————————————————————————————————————————————————
task lint, "Format and lint all sources":
  exec "nimpretty --indent:2 --maxLineLen:106 src/**/*.nim"

task bench, "Run benchmark mode and print timings":
  exec "nLauncher --bench"

task test, "Run test suite (not yet implemented)":
  echo "No tests defined yet"

