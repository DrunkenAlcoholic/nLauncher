## utils.nim ── small helpers shared by several modules
import std/[os, strutils, times, json]
import x11/[xlib, x, xft, xrender]
import state                           # display*, screen*, config, fallbackTerms

# ── Executable discovery ───────────────────────────────────────────────
proc exeExists*(exe: string): bool =
  ## True if `exe` is runnable (absolute or on $PATH).
  let e = exe.strip(chars = {'"', '\''})
  if '/' in e:
    return fileExists(e)
  for dir in getEnv("PATH","").split(':'):
    if fileExists(dir / e): return true
  false

proc chooseTerminal*(): string =
  ## First working terminal from config / $TERMINAL / fallbackTerms; else "".
  if config.terminalExe.len>0 and exeExists(config.terminalExe): return config.terminalExe
  let envT = getEnv("TERMINAL","")
  if envT.len>0 and exeExists(envT): return envT
  for t in fallbackTerms: 
    if exeExists(t): 
      return t
  ""

# ── Timing macro ───────────────────────────────────────────────────────
template timeIt*(msg: string, body: untyped) =
  let t0 = epochTime()
  body
  echo msg, " ", epochTime() - t0, "s"

# ── Colour helpers (shared by gui & launcher) ──────────────────────────
proc parseColor*(hex: string): culong =
  ## "#RRGGBB" → pixel value (returns 0 on error, already warned).
  if not (hex.len==7 and hex[0]=='#'): return 0
  try:
    let r = parseHexInt(hex[1..2])
    let g = parseHexInt(hex[3..4])
    let b = parseHexInt(hex[5..6])
    var c: XColor
    c.red   = uint16(r*257)
    c.green = uint16(g*257)
    c.blue  = uint16(b*257)
    c.flags = cast[cchar](DoRed or DoGreen or DoBlue)
    if XAllocColor(display, XDefaultColormap(display,screen), c.addr)==0: return 0
    result = c.pixel
  except: result = 0

proc allocXftColor*(hex: string, dest: var XftColor) =
  ## Fills `dest` with an allocated XftColor (raises on failure).
  if not (hex.len==7 and hex[0]=='#'): quit "invalid colour: " & hex
  let r = parseHexInt(hex[1..2])
  let g = parseHexInt(hex[3..4])
  let b = parseHexInt(hex[5..6])
  var rc: XRenderColor
  rc.red   = uint16(r*257)
  rc.green = uint16(g*257)
  rc.blue  = uint16(b*257)
  rc.alpha = 65535
  if XftColorAllocValue(display, DefaultVisual(display,screen),
                        DefaultColormap(display,screen), rc.addr,dest.addr)==0:
    quit "XftColorAllocValue failed for " & hex

let recentFile* = getHomeDir()/".cache"/"nim_launcher"/"recent.json"

proc loadRecent*() =
  if fileExists(recentFile):
    try:
      let j = parseJson(readFile(recentFile))
      state.recentApps = j.to(seq[string])
    except: discard
proc saveRecent*() =
  try:
    createDir(recentFile.parentDir)
    writeFile(recentFile, pretty(%state.recentApps))
  except: discard              # non‑fatal