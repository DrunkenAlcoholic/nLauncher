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
import std/[os, osproc, strutils, times, json, math]
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
# Convert "#RRGGBB" to 8-bit ints; returns false on bad input.
proc hexToRgb8(hex: string; r, g, b: var int): bool =
  if hex.len != 7 or hex[0] != '#': return false
  try:
    r = parseHexInt(hex[1..2]); g = parseHexInt(hex[3..4]); b = parseHexInt(hex[5..6]); true
  except: false

# sRGB → linear
proc srgbToLin(c: float): float =
  if c <= 0.04045: c / 12.92 else: pow((c + 0.055) / 1.055, 2.4)

# Relative luminance (WCAG)
proc relLuma(hex: string): float =
  var r8, g8, b8: int
  if not hexToRgb8(hex, r8, g8, b8): return 0.0
  let r = srgbToLin(r8.float / 255.0)
  let g = srgbToLin(g8.float / 255.0)
  let b = srgbToLin(b8.float / 255.0)
  0.2126*r + 0.7152*g + 0.0722*b

# Contrast ratio (WCAG)
proc contrastRatio(aHex, bHex: string): float =
  let a = relLuma(aHex); let b = relLuma(bHex)
  let (L1, L2) = if a > b: (a, b) else: (b, a)
  (L1 + 0.05) / (L2 + 0.05)

# Choose an accent that pops against bg and isn’t identical to fg
proc pickAccentColor*(bgHex, fgHex, hBgHex, hFgHex: string): string =
  var candidates = @[
    hBgHex, hFgHex,
    "#f8c291",   # amber
    "#00BFFF",   # deep sky blue
    "#FF4D4D",   # soft red
    "#00E676"    # green accent
  ]
  var best = "#f8c291"
  var bestScore = -1.0
  for c in candidates:
    if c.len != 7: continue
    let cr = contrastRatio(bgHex, c)
    # prefer high contrast; lightly penalize being too close to fg contrast
    let crFg = contrastRatio(fgHex, c)
    let score = cr*100.0 - abs(cr - crFg)*2.0
    if score > bestScore:
      bestScore = score; best = c
  best

## Parse "#RRGGBB" into 16-bit RGB components. Returns false on bad input.
proc parseHexRgb(hex: string; r, g, b: var uint16): bool =
  var r8, g8, b8: int
  if not hexToRgb8(hex, r8, g8, b8): return false
  r = uint16(r8 * 257)
  g = uint16(g8 * 257)
  b = uint16(b8 * 257)
  true

# ── Executable discovery ────────────────────────────────────────────────
## Returns true if an executable *name* can be found in $PATH (or a path).
proc whichExists*(name: string): bool =
  if name.len == 0: return false
  if name.contains('/'): return fileExists(name)
  result = findExe(name).len > 0


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
