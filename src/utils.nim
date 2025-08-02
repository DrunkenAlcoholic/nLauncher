# src/utils.nim
## utils.nim — shared helper routines
## MIT; see LICENSE for details.
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

## Quote *s* for safe use inside a shell command.
proc shellQuote*(s: string): string =
  result = "'"
  for ch in s:
    if ch == '\'':
      result.add("'\\''")
    else:
      result.add(ch)
  result.add("'")

# ── Executable discovery ────────────────────────────────────────────────
## Returns true if an executable *name* can be found in $PATH.
proc whichExists*(name: string): bool =
  for dir in getEnv("PATH").split(':'):
    if fileExists(dir / name):
      return true
  return false

## Pick a terminal emulator: prefer `config.terminalExe`, then `$TERMINAL`,
## otherwise iterate over `fallbackTerms` from `state.nim`.
proc chooseTerminal*(): string =
  ## Debug: show what we read from config
  #echo "DEBUG ▶ chooseTerminal: config.terminalExe = '", config.terminalExe, "'"
  # 1) if user explicitly set a terminal, trust it
  if config.terminalExe.len > 0:
    return config.terminalExe

  # 2) if $TERMINAL is set and executable, use it
  let envTerm = getEnv("TERMINAL")
  if envTerm.len > 0 and (fileExists(envTerm) or whichExists(envTerm)):
    #echo "DEBUG  chooseTerminal: using $TERMINAL='", envTerm, "'"
    return envTerm

  # 3) otherwise, pick from known list
  for t in fallbackTerms:
    if whichExists(t):
      #echo "DEBUG ▶ chooseTerminal: falling back to '", t, "'"
      return t

  # 4) nothing found → headless
  #echo "DEBUG ▶ chooseTerminal: no terminal found, running headless"
  return ""

# ── Timing helper (for --bench mode) ────────────────────────────────────
template timeIt*(msg: string, body: untyped) =
  ## Inline timing macro — prints *msg* and elapsed seconds.
  let t0 = epochTime()
  body
  if benchMode :
    # compute elapsed milliseconds
    let elapsed = (epochTime() - t0) * 1000.0
    # format with fixed 3 decimal places
    echo msg, " ", elapsed.formatFloat(ffDecimal, 3), " ms"

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
let recentFile* = getHomeDir() / ".cache" / "nlauncher" / "recent.json"

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
