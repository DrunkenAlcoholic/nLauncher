## state.nim — centralised data definitions & global state
## GNU GPL v3 (or later); see LICENSE.
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

  ## Payload cached to `~/.cache/nim_launcher/apps.json`.
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

# ── Constants ───────────────────────────────────────────────────────────
const
  ## Hard‑coded terminal fallback search order.
  fallbackTerms* = [
    "kitty", "alacritty", "wezterm", "foot",
    "gnome-terminal", "konsole", "xfce4-terminal", "xterm"
  ]
  maxRecent* = 10

const iniTemplate* = """
[window]
width              = 500
max_visible_items  = 10
center             = true
position_x         = 20
position_y         = 50
vertical_align     = "one-third"

[font]
fontname = Noto Sans:size=12

[input]
prompt   = "> "
cursor   = "_"

[terminal]
program  = gnome-terminal

[border]
width    = 2

[colors]
background           = "#2E3440"
foreground           = "#D8DEE9"
highlight_background = "#88C0D0"
highlight_foreground = "#2E3440"
border_color         = "#8BE9FD"

[theme]
# Leaving this empty will use the colour scheme in the [colors] section. 
# or choose one of the inbuilt themes below to override by un-commenting.
#name = "Ayu Dark"
#name = "Ayu Light"
#name = "Catppuccin Frappe"
#name = "Catppuccin Latte"
#name = "Catppuccin Macchiato"
#name = "Catppuccin Mocha"
#name = "Cobalt"
#name = "Dracula"
#name = "GitHub Dark"
#name = "GitHub Light"
#name = "Gruvbox Dark"
#name = "Gruvbox Light"
#name = "Material Dark"
#name = "Material Light"
#name = "Monokai"
#name = "Monokai Pro"
#name = "Nord"
#name = "One Dark"
#name = "One Light"
#name = "Palenight"
#name = "Solarized Dark"
#name = "Solarized Light"
#name = "Synthwave 84"
#name = "Tokyo Night"
#name = "Tokyo Night Light"

"""