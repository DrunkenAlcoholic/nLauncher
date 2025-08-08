# src/utils.nim
## utils.nim — shared helper routines
## MIT; see LICENSE for details.
##
## This unit is *side-effect-free* except for:
##   • colour allocation on an open X11 display
##   • recent-application JSON persistence
##
## All exported symbols are marked with `*`.

# ── Imports ─────────────────────────────────────────────────────────────
import std/[os, strutils, times, json, math]
import x11/[xlib, x, xft, xrender]
import state

## Quote *s* for safe use inside a shell command.
proc shellQuote*(s: string): string =
  result = "'"
  for ch in s:
    if ch == '\'':
      result.add("'\\''")
    else:
      result.add(ch)
  result.add("'")

# ── Small shared helper (DRY for color parsing) ─────────────────────────
## Parse "#RRGGBB" into 16-bit RGB components. Returns false on bad input.
proc parseHexRgb(hex: string; r, g, b: var uint16): bool =
  if hex.len != 7 or hex[0] != '#': return false
  try:
    let r8 = parseHexInt(hex[1..2])
    let g8 = parseHexInt(hex[3..4])
    let b8 = parseHexInt(hex[5..6])
    r = uint16(r8 * 257)
    g = uint16(g8 * 257)
    b = uint16(b8 * 257)
    true
  except:
    false

# ── Executable discovery ────────────────────────────────────────────────
## Returns true if an executable *name* can be found in $PATH (or a path).
proc whichExists*(name: string): bool =
  # If it's an explicit path, just check presence.
  if name.contains('/') and fileExists(name):
    return true
  # Use stdlib PATH resolver first (handles executability & PATH semantics).
  let hit = findExe(name)
  if hit.len > 0:
    return true
  # Defensive fallback (odd PATH envs).
  for dir in getEnv("PATH").split(':'):
    if dir.len == 0: continue
    if fileExists(dir / name):
      return true
  false

## Pick a terminal emulator: prefer `config.terminalExe`, then `$TERMINAL`,
## otherwise iterate over `fallbackTerms` from `state.nim`.
proc chooseTerminal*(): string =
  # 1) if user explicitly set a terminal, trust it
  if config.terminalExe.len > 0:
    return config.terminalExe

  # 2) if $TERMINAL is set and resolvable, use it
  let envTerm = getEnv("TERMINAL")
  if envTerm.len > 0 and whichExists(envTerm):
    return envTerm

  # 3) otherwise, pick from known list
  for t in fallbackTerms:
    if whichExists(t):
      return t

  # 4) nothing found → headless
  return ""

# ── Timing helper (for --bench mode) ────────────────────────────────────
template timeIt*(msg: string, body: untyped) =
  ## Inline timing macro — prints *msg* and elapsed milliseconds if benchMode.
  let t0 = epochTime()
  body
  if benchMode:
    let elapsed = (epochTime() - t0) * 1000.0
    echo msg, " ", elapsed.formatFloat(ffDecimal, 3), " ms"

# ── Colour utilities (used by gui & launcher) ───────────────────────────
proc parseColor*(hex: string): culong =
  ## Convert "#RRGGBB" → X pixel; returns 0 on failure.
  var r, g, b: uint16
  if not parseHexRgb(hex, r, g, b):
    return 0
  var c: XColor
  c.red   = r
  c.green = g
  c.blue  = b
  c.flags = cast[cchar](DoRed or DoGreen or DoBlue)
  if XAllocColor(display, XDefaultColormap(display, screen), c.addr) == 0:
    return 0
  c.pixel

proc allocXftColor*(hex: string, dest: var XftColor) =
  ## Allocate an XftColor for the current `display`/`screen`.
  var r, g, b: uint16
  if not parseHexRgb(hex, r, g, b):
    quit "invalid colour: " & hex
  var rc: XRenderColor
  rc.red   = r
  rc.green = g
  rc.blue  = b
  rc.alpha = 65535
  if XftColorAllocValue(display,
                        DefaultVisual(display, screen),
                        DefaultColormap(display, screen),
                        rc.addr, dest.addr) == 0:
    quit "XftColorAllocValue failed for " & hex

# ── Recent-apps persistence ─────────────────────────────────────────────
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
    discard         # non-fatal
