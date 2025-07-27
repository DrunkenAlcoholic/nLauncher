# src/state.nim

#──────────────────────────────────────────────────────────────────────────────
#  Imports
#──────────────────────────────────────────────────────────────────────────────
import x11/[xlib, x] ## for PDisplay, Window, GC, culong, etc.

#──────────────────────────────────────────────────────────────────────────────
#  Application & cache records
#──────────────────────────────────────────────────────────────────────────────

type
  DesktopApp* = object ## Parsed fields from a *.desktop* file (subset we care about).
    name*: string ## Display name
    exec*: string ## Command line (may contain % codes)
    hasIcon*: bool ## True if Icon= present in the file

  CacheData* = object ## JSON‑serialised on disk for fast start‑up.
    usrMtime*: float ## mtime of /usr/share/applications
    localMtime*: float ## mtime of ~/.local/share/applications
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
