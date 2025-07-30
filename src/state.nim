# src/state.nim
## state.nim — centralised data definitions & global state
## MIT; see LICENSE for details.
##
## This module is intentionally logic‑free.  It defines:
## • App/cache/config structures
## • Runtime state variables
## • Small immutable project‑wide constants
##
## All fields accessed by other modules are exported with `*`.

import x11/[xlib, x]         ## PDisplay, Window, GC, culong

# ── Data structures ─────────────────────────────────────────────────────
type
  ## A single launchable application parsed from a `.desktop` file.
  DesktopApp* = object
    name*, exec*: string
    hasIcon*: bool               ## Whether an icon path exists.

  ## Payload cached to `~/.cache/nLauncher/apps.json`.
  CacheData* = object
    usrMtime*, localMtime*: int64
    apps*: seq[DesktopApp]

  ## Launcher configuration populated by `initLauncherConfig`.
  Config* = object
    # Window geometry ----------------------------------------------------
    winWidth*, winMaxHeight*: int
    lineHeight*, maxVisibleItems*: int
    centerWindow*: bool
    positionX*, positionY*: int
    verticalAlign*: string        ## "top" | "center" | "one‑third"

    # Colours as hex strings (resolved to pixels in `gui.initGui`)
    bgColorHex*, fgColorHex*: string
    highlightBgColorHex*, highlightFgColorHex*: string
    borderColorHex*: string
    borderWidth*: int

    # Prompt / font / theme / terminal ----------------------------------
    prompt*, cursor*: string
    fontName*: string
    themeName*: string
    terminalExe*: string          ## Preferred terminal program

    # Resolved X pixel colours (set once the X connection is live)
    bgColor*, fgColor*, highlightBgColor*, highlightFgColor*, borderColor*: culong

  ## Input‑mode state, determined from the leading input prefix.
  InputMode* = enum
    imNormal         ## plain application search
    imRunCommand     ## "/<cmd>"
    imConfigSearch   ## "/c <query>"
    imYouTube        ## "/y <query>"
    imGoogle         ## "/g <query>"
    imWiki           ## "/w <query>"


type
  ## What kind of thing the user can pick.
  ActionKind* = enum
    akApp,        # a real .desktop application
    akRun,        # a `/…` shell command
    akConfig,     # `/c` file under ~/.config
    akYouTube,    # `/y` YouTube search
    akGoogle,     # `/g` Google search
    akWiki        # `/w` Wiki search

  ## A single selectable entry in the launcher.
  Action* = object
    kind*:   ActionKind
    label*:   string   # what gets drawn (e.g. "Firefox" or "Run: ls")
    exec*:   string   # what actually gets executed or opened
    appData*: DesktopApp  # optional for akApp; empty for other kinds


type
  Theme* = object
    name*: string
    bgColorHex*: string
    fgColorHex*: string
    highlightBgColorHex*: string
    highlightFgColorHex*: string
    borderColorHex*: string

# ── X11 handles (set in `gui.initGui`) ──────────────────────────────────
var
  display*:  PDisplay
  window*:   Window
  gc*:       GC
  screen*:   cint
  inputMode*: InputMode

# ── Runtime state ───────────────────────────────────────────────────────
var
  config*:        Config            ## Parsed launcher configuration
  allApps*:       seq[DesktopApp]
  filteredApps*:  seq[DesktopApp]   ## Full list & current view slice
  inputText*:     string            ## Raw user input
  selectedIndex*: int               ## Index into `filteredApps`
  viewOffset*:    int               ## First visible item row
  shouldExit*:    bool
  benchMode*:     bool = false      ## `--bench` flag (minimal redraws)
  recentApps*:    seq[string]       ## Most‑recent‑first app names
  seenMapNotify*:  bool = false     ## swallow first FocusOut after map
  themeList*: seq[Theme]

# ── Constants ───────────────────────────────────────────────────────────
const
  ## Hard‑coded terminal fallback search order.
  fallbackTerms* = [
    "kitty", "alacritty", "wezterm", "foot",
    "gnome-terminal", "konsole", "xfce4-terminal", "xterm"
  ]
  maxRecent* = 10

# ── Defaults as TOML text ────────────────────────────────────────────────
const defaultToml* = """
[window]
width = 500
max_visible_items = 10
center = true
position_x = 20
position_y = 50
vertical_align = "one-third"

[font]
fontname = "Noto Sans:size=12"

[input]
prompt = "> "
cursor = "_"

[terminal]
program = "kitty"

[border]
width = 2

[[themes]]
name                   = "Default"
bgColorHex             = "#2E3440"
fgColorHex             = "#D8DEE9"
highlightBgColorHex    = "#88C0D0"
highlightFgColorHex    = "#2E3440"
borderColorHex         = "#8BE9FD"

[[themes]]
name                   = "Ayu Dark"
bgColorHex             = "#0F1419"
fgColorHex             = "#BFBDB6"
highlightBgColorHex    = "#59C2FF"
highlightFgColorHex    = "#0F1419"
borderColorHex         = "#1F2328"

[[themes]]
name                   = "Ayu Light"
bgColorHex             = "#FAFAFA"
fgColorHex             = "#5C6773"
highlightBgColorHex    = "#399EE6"
highlightFgColorHex    = "#FAFAFA"
borderColorHex         = "#F0F0F0"

[[themes]]
name                   = "Catppuccin Frappe"
bgColorHex             = "#303446"
fgColorHex             = "#C6D0F5"
highlightBgColorHex    = "#8CAAEE"
highlightFgColorHex    = "#303446"
borderColorHex         = "#414559"

[[themes]]
name                   = "Catppuccin Latte"
bgColorHex             = "#EFF1F5"
fgColorHex             = "#4C4F69"
highlightBgColorHex    = "#1E66F5"
highlightFgColorHex    = "#EFF1F5"
borderColorHex         = "#BCC0CC"

[[themes]]
name                   = "Catppuccin Macchiato"
bgColorHex             = "#24273A"
fgColorHex             = "#CAD3F5"
highlightBgColorHex    = "#8AADF4"
highlightFgColorHex    = "#24273A"
borderColorHex         = "#363A4F"

[[themes]]
name                   = "Catppuccin Mocha"
bgColorHex             = "#1E1E2E"
fgColorHex             = "#CDD6F4"
highlightBgColorHex    = "#89B4FA"
highlightFgColorHex    = "#1E1E2E"
borderColorHex         = "#313244"

[[themes]]
name                   = "Cobalt"
bgColorHex             = "#002240"
fgColorHex             = "#FFFFFF"
highlightBgColorHex    = "#007ACC"
highlightFgColorHex    = "#002240"
borderColorHex         = "#003366"

[[themes]]
name                   = "Dracula"
bgColorHex             = "#282A36"
fgColorHex             = "#F8F8F2"
highlightBgColorHex    = "#BD93F9"
highlightFgColorHex    = "#282A36"
borderColorHex         = "#44475A"

[[themes]]
name                   = "GitHub Dark"
bgColorHex             = "#0D1117"
fgColorHex             = "#E6EDF3"
highlightBgColorHex    = "#388BFD"
highlightFgColorHex    = "#0D1117"
borderColorHex         = "#30363D"

[[themes]]
name                   = "GitHub Light"
bgColorHex             = "#FFFFFF"
fgColorHex             = "#1F2328"
highlightBgColorHex    = "#0969DA"
highlightFgColorHex    = "#FFFFFF"
borderColorHex         = "#D1D9E0"

[[themes]]
name                   = "Gruvbox Dark"
bgColorHex             = "#282828"
fgColorHex             = "#EBDBB2"
highlightBgColorHex    = "#83A598"
highlightFgColorHex    = "#282828"
borderColorHex         = "#3C3836"

[[themes]]
name                   = "Gruvbox Light"
bgColorHex             = "#FBF1C7"
fgColorHex             = "#3C3836"
highlightBgColorHex    = "#83A598"
highlightFgColorHex    = "#FBF1C7"
borderColorHex         = "#EBDBB2"

[[themes]]
name                = "Legacy"
bgColorHex          = "#14191f"
fgColorHex          = "#aec2e0"
highlightBgColorHex = "#1b232c"
highlightFgColorHex = "#aec2e0"
borderColorHex      = "#324357"

[[themes]]
name                   = "Material Dark"
bgColorHex             = "#263238"
fgColorHex             = "#ECEFF1"
highlightBgColorHex    = "#FFAB40"
highlightFgColorHex    = "#263238"
borderColorHex         = "#37474F"

[[themes]]
name                   = "Material Light"
bgColorHex             = "#FAFAFA"
fgColorHex             = "#212121"
highlightBgColorHex    = "#FFAB40"
highlightFgColorHex    = "#FAFAFA"
borderColorHex         = "#BDBDBD"

[[themes]]
name                = "Mellow Contrast"
bgColorHex          = "#0b0a09"
fgColorHex          = "#f8f8f2"
highlightBgColorHex = "#13110f"
highlightFgColorHex = "#f8f8f2"
borderColorHex      = "#7a7267"

[[themes]]
name                   = "Monokai"
bgColorHex             = "#272822"
fgColorHex             = "#F8F8F2"
highlightBgColorHex    = "#66D9EF"
highlightFgColorHex    = "#272822"
borderColorHex         = "#49483E"

[[themes]]
name                   = "Monokai Pro"
bgColorHex             = "#2D2A2E"
fgColorHex             = "#FCFCFA"
highlightBgColorHex    = "#78DCE8"
highlightFgColorHex    = "#2D2A2E"
borderColorHex         = "#5B595C"

[[themes]]
name                   = "Nord"
bgColorHex             = "#2E3440"
fgColorHex             = "#D8DEE9"
highlightBgColorHex    = "#88C0D0"
highlightFgColorHex    = "#2E3440"
borderColorHex         = "#4C566A"

[[themes]]
name                   = "One Dark"
bgColorHex             = "#282C34"
fgColorHex             = "#ABB2BF"
highlightBgColorHex    = "#61AFEF"
highlightFgColorHex    = "#282C34"
borderColorHex         = "#3E4451"

[[themes]]
name                   = "One Light"
bgColorHex             = "#FAFAFA"
fgColorHex             = "#383A42"
highlightBgColorHex    = "#4078F2"
highlightFgColorHex    = "#FAFAFA"
borderColorHex         = "#E5E5E6"

[[themes]]
name                   = "Palenight"
bgColorHex             = "#292D3E"
fgColorHex             = "#EEFFFF"
highlightBgColorHex    = "#82AAFF"
highlightFgColorHex    = "#292D3E"
borderColorHex         = "#444267"

[[themes]]
name                   = "Solarized Dark"
bgColorHex             = "#002B36"
fgColorHex             = "#839496"
highlightBgColorHex    = "#268BD2"
highlightFgColorHex    = "#002B36"
borderColorHex         = "#073642"

[[themes]]
name                   = "Solarized Light"
bgColorHex             = "#FDF6E3"
fgColorHex             = "#657B83"
highlightBgColorHex    = "#268BD2"
highlightFgColorHex    = "#FDF6E3"
borderColorHex         = "#EEE8D5"

[[themes]]
name                   = "Synthwave 84"
bgColorHex             = "#2A2139"
fgColorHex             = "#FFFFFF"
highlightBgColorHex    = "#F92AAD"
highlightFgColorHex    = "#2A2139"
borderColorHex         = "#495495"

[[themes]]
name                   = "Tokyo Night"
bgColorHex             = "#1A1B26"
fgColorHex             = "#A9B1D6"
highlightBgColorHex    = "#7AA2F7"
highlightFgColorHex    = "#1A1B26"
borderColorHex         = "#32344A"

[[themes]]
name                   = "Tokyo Night Light"
bgColorHex             = "#D5D6DB"
fgColorHex             = "#343B58"
highlightBgColorHex    = "#34548A"
highlightFgColorHex    = "#D5D6DB"
borderColorHex         = "#CBCCD1"

# remember last used
[theme]
last_chosen = "Default"
"""