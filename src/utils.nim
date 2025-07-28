#──────────────────────────────────────────────────────────────────────────────
#  utils.nim — Shared helpers used across nim_launcher modules
#──────────────────────────────────────────────────────────────────────────────

import std/[os, strutils, times, json]
import x11/[xlib, x, xft, xrender]
import state  # for: display, screen, config, fallbackTerms, recentApps

#──────────────────────────────────────────────────────────────────────────────
#  Executable Discovery
#──────────────────────────────────────────────────────────────────────────────

proc exeExists*(exe: string): bool =
  ## Returns true if the executable is found on $PATH or as absolute path.
  let e = exe.strip(chars = {'"', '\''})
  if '/' in e:
    return fileExists(e)
  for dir in getEnv("PATH", "").split(':'):
    if fileExists(dir / e): return true
  result = false

proc chooseTerminal*(): string =
  ## Chooses the first available terminal, checking config, $TERMINAL, then fallback list.
  if config.terminalExe.len > 0 and exeExists(config.terminalExe):
    return config.terminalExe

  let envT = getEnv("TERMINAL", "")
  if envT.len > 0 and exeExists(envT):
    return envT

  for t in fallbackTerms:
    if exeExists(t):
      return t

  result = ""

#──────────────────────────────────────────────────────────────────────────────
#  Timing Utility
#──────────────────────────────────────────────────────────────────────────────

template timeIt*(msg: string, body: untyped) =
  ## Prints timing info for a code block, prefixed with `msg`.
  let t0 = epochTime()
  body
  echo msg, " ", epochTime() - t0, "s"

#──────────────────────────────────────────────────────────────────────────────
#  Color Helpers for Xlib + Xft
#──────────────────────────────────────────────────────────────────────────────

proc parseColor*(hex: string): culong =
  ## Parses "#RRGGBB" to a pixel value via XAllocColor (returns 0 on failure).
  if not (hex.len == 7 and hex[0] == '#'): return 0
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
    result = 0

proc allocXftColor*(hex: string, dest: var XftColor) =
  ## Parses "#RRGGBB" to an XftColor and fills `dest`, quitting on failure.
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

#──────────────────────────────────────────────────────────────────────────────
#  Recently Used App Tracker
#──────────────────────────────────────────────────────────────────────────────

let recentFile* = getHomeDir() / ".cache" / "nim_launcher" / "recent.json"

proc loadRecent*() =
  ## Loads recent apps list from JSON file into state.recentApps.
  if fileExists(recentFile):
    try:
      let j = parseJson(readFile(recentFile))
      state.recentApps = j.to(seq[string])
    except:
      discard

proc saveRecent*() =
  ## Saves state.recentApps to recent.json in user cache.
  try:
    createDir(recentFile.parentDir)
    writeFile(recentFile, pretty(%state.recentApps))
  except:
    discard  # non-fatal