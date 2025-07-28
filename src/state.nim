# src/state.nim

#──────────────────────────────────────────────────────────────────────────────
#  Imports
#──────────────────────────────────────────────────────────────────────────────
import x11/[xlib, x] ## for PDisplay, Window, GC, culong, etc.
import std/[os, strutils]

#──────────────────────────────────────────────────────────────────────────────
#  Application & cache records
#──────────────────────────────────────────────────────────────────────────────

type
  DesktopApp* = object ## Parsed fields from a *.desktop* file (subset we care about).
    name*: string ## Display name
    exec*: string ## Command line (may contain % codes)
    hasIcon*: bool ## True if Icon= present in the file

  CacheData* = object ## JSON‑serialised on disk for fast start‑up.
    usrMtime*: int64 ## mtime of /usr/share/applications
    localMtime*: int64 ## mtime of ~/.local/share/applications
    apps*: seq[DesktopApp] ## De‑duplicated application list

#──────────────────────────────────────────────────────────────────────────────
#  GUI & config records
#──────────────────────────────────────────────────────────────────────────────

type Config* = object
  ## User‑tweakable launcher settings (loaded from INI).
  # — Window geometry —
  winWidth*, winMaxHeight*: int
  lineHeight*, maxVisibleItems*: int
  centerWindow*: bool
  positionX*, positionY*: int
  verticalAlign*: string ## "top", "center", "one-third"

  # — Colours (hex strings) —
  bgColorHex*, fgColorHex*: string
  highlightBgColorHex*, highlightFgColorHex*: string
  borderColorHex*: string

  borderWidth*: int

  # — Prompt & font —
  prompt*, cursor*: string
  fontName*: string

  # — Terminal —
  terminalExe*: string ## path to program icon (if any)

  # — Theme selection —
  themeName*: string ## empty ⇒ custom colours

  # — Runtime‑parsed X11 pixels (set after display open) —
  bgColor*, fgColor*: culong
  highlightBgColor*, highlightFgColor*: culong
  borderColor*: culong

type InputMode* = enum ## Current interpretation of user input
  imNormal # regular fuzzy‑app search
  imRunCommand # `/...`
  imConfigSearch # `/c ...`
  imYouTube # `/y ...`
  imGoogle # `/g ...`

#──────────────────────────────────────────────────────────────────────────────
#  Global singletons (mutable)  — accessed from gui & launcher
#──────────────────────────────────────────────────────────────────────────────

var
  ## X11 handles (populated in gui.initGui) ------------------------
  display*: PDisplay = nil ## XOpenDisplay result
  screen*: cint = 0
  window*: Window = 0
  graphicsContext*: GC = nil

  ## User configuration -------------------------------------------
  config*: Config ## filled by nim_launcher.initLauncherConfig()

  ## Application lists --------------------------------------------
  allApps*: seq[DesktopApp] = @[] ## master list (from cache/scan)
  filteredApps*: seq[DesktopApp] = @[] ## current fuzzy‑matched view

  ## UI state ------------------------------------------------------
  selectedIndex*: int = 0 ## highlighted row in filteredApps
  viewOffset*: int = 0 ## first row currently visible
  inputText*: string = "" ## user’s typed filter string

  ## Control flag --------------------------------------------------
  shouldExit*: bool = false ## set to true → main loop quits

  ## Input mode ---------------------------------------------------
  inputMode*: InputMode = imNormal ## current interpretation of user input

const fallbackTerms* = [
  "kitty", "alacritty", "wezterm", "foot", "gnome-terminal", "konsole",
  "xfce4-terminal", "xterm",
]

proc exeExists*(exe: string): bool =
  ## True if `exe` is runnable (accepts absolute path too)
  var e = exe.strip(chars = {'"', '\''})
  if e.contains('/'): # absolute or relative path
    return fileExists(e)
  for d in getEnv("PATH", "").split(':'):
    if fileExists(d / e):
      return true
  false

proc findExe(exe: string): string =
  ## Return absolute path if exe is found in PATH, else "".
  for dir in getEnv("PATH", "").split(':'):
    let p = dir / exe
    if fileExists(p):
      return p
  result = "" # not found

proc chooseTerminal*(): string =
  ## Returns absolute path of the first usable terminal.
  # 1) config file
  if config.terminalExe.len > 0:
    let cfg = config.terminalExe.strip(chars = {'"', '\''})
    if cfg.contains('/'): # absolute path given
      if fileExists(cfg):
        return cfg
    else:
      let f = findExe(cfg)
      if f.len > 0:
        return f

  # 2) $TERMINAL
  let envTerm = getEnv("TERMINAL", "")
  if envTerm.len > 0:
    if envTerm.contains('/'): # absolute
      if fileExists(envTerm):
        return envTerm
    else:
      let f = findExe(envTerm)
      if f.len > 0:
        return f

  # 3) fallbacks
  for t in fallbackTerms:
    let p = findExe(t)
    if p.len > 0:
      return p

  return "" # none found
