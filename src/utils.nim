## utils.nim — shared helper routines
## GNU GPL v3 (or later); see LICENSE for details.
##
## This unit is *side‑effect‑free* except for:
##   • colour allocation on an open X11 display
##   • recent‑application JSON persistence
##
## All exported symbols are marked with `*`.

# ── Imports ─────────────────────────────────────────────────────────────
import std/[os, strutils, times, json, math]
import x11/[xlib, x, xft, xrender]
import state           # display*, screen*, config, fallbackTerms, recentApps

# ── Executable discovery ────────────────────────────────────────────────
proc exeExists*(exe: string): bool =
  ## Return `true` if *exe* is runnable (absolute path or on $PATH).
  let clean = exe.strip(chars = {'"', '\''})
  if '/' in clean:
    return fileExists(clean)
  for dir in getEnv("PATH", "").split(':'):
    if fileExists(dir / clean):
      return true
  false

proc chooseTerminal*(): string =
  ## Select the first working terminal, respecting:
  ##   1. `config.terminalExe`
  ##   2. `$TERMINAL`
  ##   3. hard‑coded `fallbackTerms`
  if config.terminalExe.len > 0 and exeExists(config.terminalExe):
    return config.terminalExe
  let envT = getEnv("TERMINAL", "")
  if envT.len > 0 and exeExists(envT):
    return envT
  for t in fallbackTerms:
    if exeExists(t):
      return t
  ""

# ── Timing helper (for --bench mode) ────────────────────────────────────
template timeIt*(msg: string, body: untyped) =
  ## Inline timing macro — prints *msg* and elapsed seconds.
  let t0 = epochTime()
  body
  echo msg, " ", ((epochTime() - t0) * 1000).round, " ms"

# ── Colour utilities (used by gui & launcher) ───────────────────────────
proc parseColor*(hex: string): culong =
  ## Convert "#RRGGBB" → X pixel; returns 0 on failure.
  if not (hex.len == 7 and hex[0] == '#'):
    return 0
  try:
    let r = parseHexInt(hex[1..2])
    let g = parseHexInt(hex[3..4])
    let b = parseHexInt(hex[5..6])
    var c: XColor
    c.red   = uint16(r * 257)
    c.green = uint16(g * 257)
    c.blue  = uint16(b * 257)
    c.flags = cast[cchar](DoRed or DoGreen or DoBlue)
    if XAllocColor(display, XDefaultColormap(display, screen), c.addr) == 0:
      return 0
    result = c.pixel
  except:
    result = 0               # invalid hex, parseHexInt overflow…

proc allocXftColor*(hex: string, dest: var XftColor) =
  ## Allocate an XftColor for the current `display`/`screen`.
  if not (hex.len == 7 and hex[0] == '#'):
    quit "invalid colour: " & hex
  let r = parseHexInt(hex[1..2])
  let g = parseHexInt(hex[3..4])
  let b = parseHexInt(hex[5..6])
  var rc: XRenderColor
  rc.red   = uint16(r * 257)
  rc.green = uint16(g * 257)
  rc.blue  = uint16(b * 257)
  rc.alpha = 65535
  if XftColorAllocValue(display,
                        DefaultVisual(display, screen),
                        DefaultColormap(display, screen),
                        rc.addr, dest.addr) == 0:
    quit "XftColorAllocValue failed for " & hex

# ── Recent‑apps persistence ─────────────────────────────────────────────
let recentFile* = getHomeDir() / ".cache" / "nim_launcher" / "recent.json"

proc loadRecent*() =
  ## Populate `state.recentApps` from disk; silent on error.
  if fileExists(recentFile):
    try:
      let j = parseJson(readFile(recentFile))
      state.recentApps = j.to(seq[string])
    except:
      discard

proc saveRecent*() =
  ## Persist `state.recentApps` to disk; silent on error.
  try:
    createDir(recentFile.parentDir)
    writeFile(recentFile, pretty(%state.recentApps))
  except:
    discard         # non‑fatal
