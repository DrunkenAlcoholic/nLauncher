## state.nim — centralised data definitions & global state
## (No logic; only types / global vars / simple constants)

import x11/[xlib, x]

# ── Data structures ────────────────────────────────────────────────────
type
  ## A single launchable application (.desktop entry)
  DesktopApp* = object
    name*, exec*: string
    hasIcon*: bool

  ## Cached scan payload written to ~/.cache/nim_launcher/apps.json
  CacheData* = object
    usrMtime*, localMtime*: int64
    apps*: seq[DesktopApp]

  ## Launcher configuration (populated by initLauncherConfig)
  Config* = object # Window geometry
    winWidth*, winMaxHeight*: int
    lineHeight*, maxVisibleItems*: int
    centerWindow*: bool
    positionX*, positionY*: int
    verticalAlign*: string ## "top" | "center" | "one‑third"

    # Colours (hex strings from INI, resolved to X pixels at runtime)
    bgColorHex*, fgColorHex*: string
    highlightBgColorHex*, highlightFgColorHex*: string
    borderColorHex*: string
    borderWidth*: int

    # Prompt / font / theme / terminal
    prompt*, cursor*: string
    fontName*: string
    themeName*: string
    terminalExe*: string ## preferred terminal program

    # X pixel values (filled in gui.initGui)
    bgColor*, fgColor*, highlightBgColor*, highlightFgColor*, borderColor*: culong

  ## ───────────────────────────────────────────────────────────────────
  ##  Input‑mode state (determined by leading prefix)
  ## -------------------------------------------------------------------
  InputMode* = enum # <── ADD
    imNormal # plain application search
    imRunCommand # "/<cmd>"
    imConfigSearch # "/c <query>"
    imYouTube # "/y <query>"
    imGoogle # "/g <query>"

# ── X11 handles (initialised in gui.initGui) ────────────────────────────
var
  display*: PDisplay
  window*: Window
  gc*: GC
  screen*: cint
  inputMode*: InputMode

# ── Runtime state ───────────────────────────────────────────────────────
var
  config*: Config
  allApps*, filteredApps*: seq[DesktopApp]
  inputText*: string
  selectedIndex*, viewOffset*: int
  shouldExit*: bool
  benchMode*: bool = false
  recentApps*: seq[string]           ## most‑recent‑first names

# ── Terminal fallback list ──────────────────────────────────────────────
const 
  fallbackTerms* = [
  "kitty", "alacritty", "wezterm", "foot", "gnome-terminal", "konsole",
  "xfce4-terminal", "xterm"]
  maxRecent* = 10

