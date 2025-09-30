## utils.nim — shared helper routines
## MIT; see LICENSE for details.
##
## Side effects:
##   • colour allocation on an open X11 display
##   • recent-application JSON persistence

import std/[os, osproc, strutils, times, json]
import x11/[xlib, x, xft, xrender]
import ./[state, parser]

# ── Shell helpers ───────────────────────────────────────────────────────
## Quote a string for safe use inside a POSIX shell single-quoted context.
proc shellQuote*(s: string): string =
  result = "'"
  for ch in s:
    if ch == '\'':
      result.add("'\\''") # close ' … escape ' … reopen '
    else:
      result.add(ch)
  result.add("'")

# ── Colour helpers ──────────────────────────────────────────────────────
## Parse "#RRGGBB" into 8-bit channels; returns false on bad input.
proc hexToRgb8(hex: string; r, g, b: var int): bool =
  if hex.len != 7 or hex[0] != '#': return false
  try:
    r = parseHexInt(hex[1..2])
    g = parseHexInt(hex[3..4])
    b = parseHexInt(hex[5..6])
    true
  except:
    false

## Parse "#RRGGBB" into 16-bit channels (0..65535); returns false on bad input.
proc parseHexRgb(hex: string; r, g, b: var uint16): bool =
  var r8, g8, b8: int
  if not hexToRgb8(hex, r8, g8, b8): return false
  r = uint16(r8 * 257)
  g = uint16(g8 * 257)
  b = uint16(b8 * 257)
  true

## Convert "#RRGGBB" to an X11 pixel (allocates the colour in the default colormap).
proc parseColor*(hex: string): culong =
  var r, g, b: uint16
  if not parseHexRgb(hex, r, g, b):
    return 0
  var c: XColor
  c.red = r
  c.green = g
  c.blue = b
  c.flags = cast[cchar](DoRed or DoGreen or DoBlue)
  if XAllocColor(display, XDefaultColormap(display, screen), c.addr) == 0:
    return 0
  c.pixel

## Allocate an XftColor for the current display/screen.
proc allocXftColor*(hex: string; dest: var XftColor) =
  var r, g, b: uint16
  if not parseHexRgb(hex, r, g, b):
    quit "invalid colour: " & hex
  var rc: XRenderColor
  rc.red = r
  rc.green = g
  rc.blue = b
  rc.alpha = 65535
  if XftColorAllocValue(
       display,
       DefaultVisual(display, screen),
       DefaultColormap(display, screen),
       rc.addr, dest.addr) == 0:
    quit "XftColorAllocValue failed for " & hex

# ── Executable / terminal helpers ───────────────────────────────────────
## Try to start each candidate executable with arguments; return true on success.
proc tryStart(candidates: seq[(string, seq[string])]): bool =
  for (exe, args) in candidates:
    if exe.len > 0:
      try:
        discard startProcess(exe, args = args, options = {poDaemon})
        return true
      except:
        discard
  false

## Open a file with the system default handler; fall back to common editors.
proc openPathWithDefault*(path: string): bool =
  let abs = absolutePath(path)
  if not fileExists(abs): return false

  ## Preferred system openers
  if tryStart(@[(findExe("xdg-open"), @[abs]),
               (findExe("gio"), @["open", abs])]):
    return true

  ## Respect user editor preference
  var envCandidates: seq[(string, seq[string])] = @[]
  for envName in ["VISUAL", "EDITOR"]:
    let ed = getEnv(envName)
    if ed.len == 0:
      continue
    let tokens = tokenize(ed)
    if tokens.len == 0:
      continue
    let head = tokens[0]
    var exePath: string
    if head.contains('/'):
      exePath = expandFilename(head)
      if not fileExists(exePath):
        exePath = ""
    else:
      exePath = findExe(head)
    if exePath.len == 0:
      continue
    var args: seq[string] = @[]
    if tokens.len > 1:
      args = tokens[1 ..< tokens.len]
    args.add abs
    envCandidates.add((exePath, args))
  if tryStart(envCandidates):
    return true

  ## Fallback shortlist
  var fallbackCandidates: seq[(string, seq[string])] = @[]
  for ed in ["gedit", "kate", "mousepad", "code", "nano", "vi"]:
    let exe = findExe(ed)
    if exe.len > 0:
      fallbackCandidates.add((exe, @[abs]))
  if tryStart(fallbackCandidates):
    return true

  false

## Open files or directories, falling back to xdg-open when needed.
proc openPathWithFallback*(path: string): bool =
  let resolved = path.expandTilde()
  if openPathWithDefault(resolved): return true
  if dirExists(resolved) or fileExists(resolved):
    try:
      discard startProcess("/usr/bin/env", args = @["xdg-open", resolved], options = {poDaemon})
      return true
    except CatchableError:
      discard
  false

## True if an executable can be found in $PATH (or is a path that exists).
proc whichExists*(name: string): bool =
  if name.len == 0: return false
  if name.contains('/'): return fileExists(name)
  findExe(name).len > 0

## Pick a terminal emulator: prefer config.terminalExe, then $TERMINAL, then fallbacks.
proc chooseTerminal*(): string =
  ## Prefer configured terminal when it exists; else known fallbacks.
  if config.terminalExe.len > 0:
    let tokens = tokenize(config.terminalExe)
    if tokens.len > 0 and whichExists(tokens[0]):
      return config.terminalExe
  let envTerm = getEnv("TERMINAL")
  if envTerm.len > 0:
    let tokens = tokenize(envTerm)
    if tokens.len > 0 and whichExists(tokens[0]):
      return envTerm
  for t in fallbackTerms:
    if whichExists(t):
      return t
  ""  # headless


# ── Timing helper (for --bench mode) ────────────────────────────────────
template timeIt*(msg: string; body: untyped) =
  let t0 = epochTime()
  body
  if benchMode:
    let elapsed = (epochTime() - t0) * 1000.0
    echo msg, " ", elapsed.formatFloat(ffDecimal, 3), " ms"

# ── Recent/MRU (applications) persistence ───────────────────────────────
let recentFile* = getHomeDir() / ".cache" / "nlauncher" / "recent.json"

proc loadRecent*() =
  ## Populate state.recentApps from disk; log on error.
  if fileExists(recentFile):
    try:
      let j = parseJson(readFile(recentFile))
      state.recentApps = j.to(seq[string])
    except CatchableError as e:
      echo "loadRecent warning: ", recentFile, " (", e.name, "): ", e.msg

proc saveRecent*() =
  ## Persist state.recentApps to disk; log on error.
  try:
    createDir(recentFile.parentDir)
    writeFile(recentFile, pretty(%state.recentApps))
  except CatchableError as e:
    echo "saveRecent warning: ", recentFile, " (", e.name, "): ", e.msg
