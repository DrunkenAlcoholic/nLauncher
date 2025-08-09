## state.nim — centralised data definitions & global state
## MIT; see LICENSE for details.
##
## Defines:
## • App/cache/config structures
## • Runtime state variables
## • Immutable project-wide constants
##
## This module is intentionally logic-free.

import x11/[xlib, x]         ## PDisplay, Window, GC, culong

# ── Data structures ─────────────────────────────────────────────────────
type
  ## A single launchable application parsed from a `.desktop` file.
  DesktopApp* = object
    name*, exec*: string
    hasIcon*: bool

  ## Payload cached to `~/.cache/nlauncher/apps.json`.
  CacheData* = object
    usrMtime*, localMtime*: int64
    apps*: seq[DesktopApp]

  ## Launcher configuration populated by initLauncherConfig.
  Config* = object
    # Window geometry ----------------------------------------------------
    winWidth*, winMaxHeight*: int
    lineHeight*, maxVisibleItems*: int
    centerWindow*: bool
    positionX*, positionY*: int
    verticalAlign*: string        ## "top" | "center" | "one-third"

    # Colours as hex strings (resolved to pixels in gui.initGui) ---------
    bgColorHex*, fgColorHex*: string
    highlightBgColorHex*, highlightFgColorHex*: string
    borderColorHex*: string
    borderWidth*: int
    matchFgColorHex*: string      ## color for matched letters (e.g. "#FF00FF")

    # Prompt / font / theme / terminal ----------------------------------
    prompt*, cursor*: string
    fontName*: string
    themeName*: string
    terminalExe*: string          ## preferred terminal program

    # Resolved X pixel colours (set once the X connection is live) -------
    bgColor*, fgColor*, highlightBgColor*, highlightFgColor*, borderColor*: culong

type
  ## What kind of thing the user can pick.
  ActionKind* = enum
    akApp,        # a real .desktop application
    akRun,        # a `/…` shell command
    akConfig,     # `/c` file under ~/.config
    akYouTube,    # `/y` YouTube search
    akGoogle,     # `/g` Google search
    akWiki        # `/w` Wiki search
    akTheme       # `/t` Theme selector

  ## A single selectable entry in the launcher.
  Action* = object
    kind*:    ActionKind
    label*:   string   # what gets drawn (e.g. "Firefox" or "Run: ls")
    exec*:    string   # what actually gets executed or opened
    appData*: DesktopApp  # optional for akApp; empty for other kinds

  ## Theme definition (matchFgColorHex is explicit; no "auto" support).
  Theme* = object
    name*: string
    bgColorHex*: string
    fgColorHex*: string
    highlightBgColorHex*: string
    highlightFgColorHex*: string
    borderColorHex*: string
    matchFgColorHex*: string      ## leave empty to inherit Config.matchFgColorHex

# ── X11 handles (set in `gui.initGui`) ──────────────────────────────────
var
  display*:  PDisplay
  window*:   Window
  gc*:       GC
  screen*:   cint

# ── Runtime state ───────────────────────────────────────────────────────
var
  config*:        Config            ## parsed launcher configuration
  allApps*:       seq[DesktopApp]
  filteredApps*:  seq[DesktopApp]   ## full list & current view slice
  inputText*:     string            ## raw user input
  selectedIndex*: int               ## index into `filteredApps`
  viewOffset*:    int               ## first visible item row
  shouldExit*:    bool
  benchMode*:     bool = false      ## `--bench` flag (minimal redraws)
  recentApps*:    seq[string]       ## most-recent-first app names
  seenMapNotify*: bool = false      ## swallow first FocusOut after map
  themeList*:     seq[Theme]
  matchSpans*:    seq[seq[(int,int)]]   ## per row: (start,len) spans to highlight

# ── Constants ───────────────────────────────────────────────────────────
const
  ## Hard-coded terminal fallback search order.
  fallbackTerms* = [
    "kitty", "alacritty", "wezterm", "foot",
    "gnome-terminal", "konsole", "xfce4-terminal", "xterm"
  ]
  maxRecent* = 10

# ── Defaults as TOML text ───────────────────────────────────────────────
const defaultToml* = """
# ==========================
# nLauncher Configuration
# ==========================
# This file controls how nLauncher looks and behaves.
# All settings are optional — if removed, defaults will be used.
# Edit values, save, and restart nLauncher to apply changes.
# Colors must be in HEX format (e.g., "#RRGGBB").

[window]
width = 500                       # Width of the launcher window in pixels
max_visible_items = 10            # Number of items visible at once (affects height)
center = true                     # true: center window horizontally; false: use position_x/position_y
position_x = 20                   # X position in pixels when center=false
position_y = 500                  # Y position in pixels when center=false
vertical_align = "one-third"      # Only used when center=true; "top", "center", or "one-third"

[font]
fontname = "Noto Sans:size=12"    # Font name & size (Xft format: "Font Family:size=N")

[input]
prompt = "> "                     # Prompt prefix shown before your query
cursor = "_"                      # Cursor character displayed after query text

[terminal]
program = "gnome-terminal"        # Terminal emulator for slash commands (/ ...)
                                  # If not found, nLauncher will fall back to a default

[border]
width = 2                         # Border thickness in pixels (0 = no border)

# ==========================
# Themes
# ==========================
# Add or remove [[themes]] blocks to customize appearance.
# The "name" field is what you'll see in the theme selector (/t or F5).
# Colors:
#   bgColorHex          = Window background
#   fgColorHex          = Normal text color
#   highlightBgColorHex = Background of selected/highlighted item
#   highlightFgColorHex = Text color of selected/highlighted item
#   borderColorHex      = Window border color
#   matchFgColorHex     = Color for matching characters in search results
#
# Tip: You can quickly preview themes in-app with the `/t` command.

[[themes]]
name                = "Arstotzka"   
bgColorHex          = "#211f1e"
fgColorHex          = "#edebe6"
highlightBgColorHex = "#292725"
highlightFgColorHex = "#edebe6"
borderColorHex      = "#3f3a36"
matchFgColorHex     = "#516b6b"

[[themes]]
name                = "Ayu Dark"
bgColorHex          = "#0F1419"
fgColorHex          = "#BFBDB6"
highlightBgColorHex = "#59C2FF"
highlightFgColorHex = "#0F1419"
borderColorHex      = "#1F2328"
matchFgColorHex     = ""

[[themes]]
name                = "Ayu Light"
bgColorHex          = "#FAFAFA"
fgColorHex          = "#5C6773"
highlightBgColorHex = "#399EE6"
highlightFgColorHex = "#FAFAFA"
borderColorHex      = "#F0F0F0"
matchFgColorHex     = ""

[[themes]]
name                = "Azure"
bgColorHex          = "#181d26"
fgColorHex          = "#ffffff"
highlightBgColorHex = "#33333c"
highlightFgColorHex = "#ffffff"
borderColorHex      = "#414d62"
matchFgColorHex     = "#52708b"

[[themes]]
name                = "Bold"
bgColorHex          = "#2a2626"
fgColorHex          = "#ffffff"
highlightBgColorHex = "#393434"
highlightFgColorHex = "#ffffff"
borderColorHex      = "#534b4b"
matchFgColorHex     = "#f0624b"

[[themes]]
name                = "Box UK"
bgColorHex          = "#ffffff"
fgColorHex          = "#414f5c"
highlightBgColorHex = "#eeeeee"
highlightFgColorHex = "#414f5c"
borderColorHex      = "#b8b6b1"
matchFgColorHex     = "#019d76"

[[themes]]
name                = "Carbonight"
bgColorHex          = "#2e2c2b"
fgColorHex          = "#b0b0b0"
highlightBgColorHex = "#3b3633"
highlightFgColorHex = "#2e2c2b"
borderColorHex      = "#423f3d"
matchFgColorHex     = "#8c8c8c"

[[themes]]
name                = "Carbonight Contrast"
bgColorHex          = "#000000"
fgColorHex          = "#ffffff"
highlightBgColorHex = "#151515"
highlightFgColorHex = "#ffffff"
borderColorHex      = "#423f3d"
matchFgColorHex     = "#8c8c8c"

[[themes]]
name                = "Catppuccin Frappe"
bgColorHex          = "#303446"
fgColorHex          = "#C6D0F5"
highlightBgColorHex = "#8CAAEE"
highlightFgColorHex = "#303446"
borderColorHex      = "#414559"
matchFgColorHex     = ""

[[themes]]
name                = "Catppuccin Latte"
bgColorHex          = "#EFF1F5"
fgColorHex          = "#4C4F69"
highlightBgColorHex = "#1E66F5"
highlightFgColorHex = "#EFF1F5"
borderColorHex      = "#BCC0CC"
matchFgColorHex     = ""

[[themes]]
name                = "Catppuccin Macchiato"
bgColorHex          = "#24273A"
fgColorHex          = "#CAD3F5"
highlightBgColorHex = "#8AADF4"
highlightFgColorHex = "#24273A"
borderColorHex      = "#363A4F"
matchFgColorHex     = ""

[[themes]]
name                = "Catppuccin Mocha"
bgColorHex          = "#1E1E2E"
fgColorHex          = "#CDD6F4"
highlightBgColorHex = "#89B4FA"
highlightFgColorHex = "#1E1E2E"
borderColorHex      = "#313244"
matchFgColorHex     = ""

[[themes]]
name                = "Charcoal Dark"
bgColorHex          = "#120F09"
fgColorHex          = "#C0A179"
highlightBgColorHex = "#35291D"
highlightFgColorHex = "#D6B891"
borderColorHex      = "#887254"
matchFgColorHex     = ""

[[themes]]
name                = "Charcoal Light"
bgColorHex          = "#d6b891"
fgColorHex          = "#35291d"
highlightBgColorHex = "#a28662"
highlightFgColorHex = "#120f09"
borderColorHex      = "#66553f"
matchFgColorHex     = ""

[[themes]]
name                = "Chocolate"
bgColorHex          = "#150f08"
fgColorHex          = "#ffffff"
highlightBgColorHex = "#362715"
highlightFgColorHex = "#ffffff"
borderColorHex      = "#795431"
matchFgColorHex     = "#ccb697"

[[themes]]
name                = "Cobalt"
bgColorHex          = "#002240"
fgColorHex          = "#FFFFFF"
highlightBgColorHex = "#007ACC"
highlightFgColorHex = "#002240"
borderColorHex      = "#003366"
matchFgColorHex     = ""

[[themes]]
name                = "Crisp"
bgColorHex          = "#221a22"
fgColorHex          = "#ffffff"
highlightBgColorHex = "#1c151c"
highlightFgColorHex = "#ffffff"
borderColorHex      = "#574457"
matchFgColorHex     = "#765478"

[[themes]]
name                = "Darkside"
bgColorHex          = "#222324"
fgColorHex          = "#bababa"
highlightBgColorHex = "#303333"
highlightFgColorHex = "#bababa"
borderColorHex      = "#494b4d"
matchFgColorHex     = "#e8341c"

[[themes]]
name                = "Darkside Contrast"
bgColorHex          = "#000000"
fgColorHex          = "#bababa"
highlightBgColorHex = "#151515"
highlightFgColorHex = "#bababa"
borderColorHex      = "#494b4d"
matchFgColorHex     = "#e8341c"

[[themes]]
name                = "Default"
bgColorHex          = "#2E3440"
fgColorHex          = "#D8DEE9"
highlightBgColorHex = "#88C0D0"
highlightFgColorHex = "#2E3440"
borderColorHex      = "#8BE9FD"
matchFgColorHex     = "#f8c291"

[[themes]]
name                = "Dracula"
bgColorHex          = "#282A36"
fgColorHex          = "#F8F8F2"
highlightBgColorHex = "#BD93F9"
highlightFgColorHex = "#282A36"
borderColorHex      = "#44475A"
matchFgColorHex     = ""

[[themes]]
name                = "Earthsong"
bgColorHex          = "#36312c"
fgColorHex          = "#ebd1b7"
highlightBgColorHex = "#45403b"
highlightFgColorHex = "#ebd1b7"
borderColorHex      = "#7a7267"
matchFgColorHex     = "#db784d"

[[themes]]
name                = "Earthsong Contrast"
bgColorHex          = "#12100f"
fgColorHex          = "#ebd1b7"
highlightBgColorHex = "#282521"
highlightFgColorHex = "#ebd1b7"
borderColorHex      = "#7a7267"
matchFgColorHex     = "#db784d"

[[themes]]
name                = "Earthsong Light"
bgColorHex          = "#ffffff"
fgColorHex          = "#4d463e"
highlightBgColorHex = "#eeeeee"
highlightFgColorHex = "#4d463e"
borderColorHex      = "#d6cab9"
matchFgColorHex     = "#db784d"

[[themes]]
name                = "FreshCut"
bgColorHex          = "#2f3030"
fgColorHex          = "#f8f8f2"
highlightBgColorHex = "#383939"
highlightFgColorHex = "#f8f8f2"
borderColorHex      = "#737b84"
matchFgColorHex     = "#00a8c6"

[[themes]]
name                = "FreshCut Contrast"
bgColorHex          = "#000000"
fgColorHex          = "#f8f8f2"
highlightBgColorHex = "#151515"
highlightFgColorHex = "#f8f8f2"
borderColorHex      = "#737b84"
matchFgColorHex     = "#00a8c6"

[[themes]]
name                = "Frontier"
bgColorHex          = "#36312c"
fgColorHex          = "#f8f8f2"
highlightBgColorHex = "#45403b"
highlightFgColorHex = "#f8f8f2"
borderColorHex      = "#7a7267"
matchFgColorHex     = "#f23a3a"

[[themes]]
name                = "Frontier Contrast"
bgColorHex          = "#110f0e"
fgColorHex          = "#f8f8f2"
highlightBgColorHex = "#221f1c"
highlightFgColorHex = "#f8f8f2"
borderColorHex      = "#7a7267"
matchFgColorHex     = "#f23a3a"

[[themes]]
name                = "GitHub"
bgColorHex          = "#ffffff"
fgColorHex          = "#555555"
highlightBgColorHex = "#eeeeee"
highlightFgColorHex = "#ffffff"
borderColorHex      = "#b8b6b1"
matchFgColorHex     = "#008080"

[[themes]]
name                = "GitHub Dark"
bgColorHex          = "#0D1117"
fgColorHex          = "#E6EDF3"
highlightBgColorHex = "#388BFD"
highlightFgColorHex = "#0D1117"
borderColorHex      = "#30363D"
matchFgColorHex     = ""

[[themes]]
name                = "GitHub Light"
bgColorHex          = "#FFFFFF"
fgColorHex          = "#1F2328"
highlightBgColorHex = "#0969DA"
highlightFgColorHex = "#FFFFFF"
borderColorHex      = "#D1D9E0"
matchFgColorHex     = ""

[[themes]]
name                = "Gloom"
bgColorHex          = "#2a332b"
fgColorHex          = "#d8ebe5"
highlightBgColorHex = "#3c4d3e"
highlightFgColorHex = "#d8ebe5"
borderColorHex      = "#4f6e64"
matchFgColorHex     = "#ff5d38"

[[themes]]
name                = "Gloom Contrast"
bgColorHex          = "#0f120f"
fgColorHex          = "#d8ebe5"
highlightBgColorHex = "#1b211c"
highlightFgColorHex = "#d8ebe5"
borderColorHex      = "#4f6e64"
matchFgColorHex     = "#ff5d38"

[[themes]]
name                = "Glowfish"
bgColorHex          = "#191f13"
fgColorHex          = "#6ea240"
highlightBgColorHex = "#222a1a"
highlightFgColorHex = "#6ea240"
borderColorHex      = "#3c4e2d"
matchFgColorHex     = "#db784d"

[[themes]]
name                = "Glowfish Contrast"
bgColorHex          = "#090b07"
fgColorHex          = "#6ea240"
highlightBgColorHex = "#12160d"
highlightFgColorHex = "#090b07"
borderColorHex      = "#3c4e2d"
matchFgColorHex     = "#db784d"

[[themes]]
name                = "Goldfish"
bgColorHex          = "#2e3336"
fgColorHex          = "#f8f8f2"
highlightBgColorHex = "#465459"
highlightFgColorHex = "#2e3336"
borderColorHex      = "#505c63"
matchFgColorHex     = "#fa6900"

[[themes]]
name                = "Goldfish Contrast"
bgColorHex          = "#0c0d0e"
fgColorHex          = "#f8f8f2"
highlightBgColorHex = "#16181a"
highlightFgColorHex = "#0c0d0e"
borderColorHex      = "#505c63"
matchFgColorHex     = "#fa6900"

[[themes]]
name                = "Grunge"
bgColorHex          = "#31332c"
fgColorHex          = "#f8f8f2"
highlightBgColorHex = "#41453a"
highlightFgColorHex = "#31332c"
borderColorHex      = "#5c634f"
matchFgColorHex     = "#f56991"

[[themes]]
name                = "Grunge Contrast"
bgColorHex          = "#0c0c0a"
fgColorHex          = "#f8f8f2"
highlightBgColorHex = "#1b1c18"
highlightFgColorHex = "#0c0c0a"
borderColorHex      = "#5c634f"
matchFgColorHex     = "#f56991"

[[themes]]
name                = "Gruvbox Dark"
bgColorHex          = "#282828"
fgColorHex          = "#EBDBB2"
highlightBgColorHex = "#83A598"
highlightFgColorHex = "#282828"
borderColorHex      = "#3C3836"
matchFgColorHex     = ""

[[themes]]
name                = "Gruvbox Light"
bgColorHex          = "#FBF1C7"
fgColorHex          = "#3C3836"
highlightBgColorHex = "#83A598"
highlightFgColorHex = "#FBF1C7"
borderColorHex      = "#EBDBB2"
matchFgColorHex     = ""

[[themes]]
name                = "Halflife"
bgColorHex          = "#222222"
fgColorHex          = "#cccccc"
highlightBgColorHex = "#282828"
highlightFgColorHex = "#222222"
borderColorHex      = "#555555"
matchFgColorHex     = "#7d8991"

[[themes]]
name                = "Halflife Contrast"
bgColorHex          = "#000000"
fgColorHex          = "#cccccc"
highlightBgColorHex = "#151515"
highlightFgColorHex = "#000000"
borderColorHex      = "#555555"
matchFgColorHex     = "#7d8991"

[[themes]]
name                = "Hyrule"
bgColorHex          = "#2d2c2b"
fgColorHex          = "#c0d5c1"
highlightBgColorHex = "#3d3934"
highlightFgColorHex = "#2d2c2b"
borderColorHex      = "#716d6a"
matchFgColorHex     = "#569e16"

[[themes]]
name                = "Hyrule Contrast"
bgColorHex          = "#0c0c0c"
fgColorHex          = "#c0d5c1"
highlightBgColorHex = "#141413"
highlightFgColorHex = "#0c0c0c"
borderColorHex      = "#716d6a"
matchFgColorHex     = "#569e16"

[[themes]]
name                = "Iceberg"
bgColorHex          = "#323b3d"
fgColorHex          = "#bdd6db"
highlightBgColorHex = "#3e4c4f"
highlightFgColorHex = "#323b3d"
borderColorHex      = "#537178"
matchFgColorHex     = "#2d8da1"

[[themes]]
name                = "Iceberg Contrast"
bgColorHex          = "#0b0e0e"
fgColorHex          = "#bdd6db"
highlightBgColorHex = "#141718"
highlightFgColorHex = "#0b0e0e"
borderColorHex      = "#537178"
matchFgColorHex     = "#2d8da1"

[[themes]]
name                = "Juicy"
bgColorHex          = "#222222"
fgColorHex          = "#e3e2e0"
highlightBgColorHex = "#282828"
highlightFgColorHex = "#222222"
borderColorHex      = "#777777"
matchFgColorHex     = "#3bc7b8"

[[themes]]
name                = "Juicy Contrast"
bgColorHex          = "#000000"
fgColorHex          = "#e3e2e0"
highlightBgColorHex = "#151515"
highlightFgColorHex = "#000000"
borderColorHex      = "#777777"
matchFgColorHex     = "#3bc7b8"

[[themes]]
name                = "Keen"
bgColorHex          = "#111111"
fgColorHex          = "#cccccc"
highlightBgColorHex = "#222222"
highlightFgColorHex = "#111111"
borderColorHex      = "#374c60"
matchFgColorHex     = "#8767b7"

[[themes]]
name                = "Keen Contrast"
bgColorHex          = "#000000"
fgColorHex          = "#ffffff"
highlightBgColorHex = "#151515"
highlightFgColorHex = "#000000"
borderColorHex      = "#374c60"
matchFgColorHex     = "#8767b7"

[[themes]]
name                = "Kiwi"
bgColorHex          = "#161a19"
fgColorHex          = "#edebe6"
highlightBgColorHex = "#282f2d"
highlightFgColorHex = "#161a19"
borderColorHex      = "#354341"
matchFgColorHex     = "#95c72a"

[[themes]]
name                = "Laravel"
bgColorHex          = "#2e2c2b"
fgColorHex          = "#dedede"
highlightBgColorHex = "#3b3633"
highlightFgColorHex = "#2e2c2b"
borderColorHex      = "#615953"
matchFgColorHex     = "#fc6b0a"

[[themes]]
name                = "Laravel Contrast"
bgColorHex          = "#000000"
fgColorHex          = "#ffffff"
highlightBgColorHex = "#151515"
highlightFgColorHex = "#000000"
borderColorHex      = "#615953"
matchFgColorHex     = "#fc6b0a"

[[themes]]
name                = "Lavender"
bgColorHex          = "#29222e"
fgColorHex          = "#e0ceed"
highlightBgColorHex = "#3a2f42"
highlightFgColorHex = "#29222e"
borderColorHex      = "#614e6e"
matchFgColorHex     = "#b657ff"

[[themes]]
name                = "Lavender Contrast"
bgColorHex          = "#080709"
fgColorHex          = "#e0ceed"
highlightBgColorHex = "#110e13"
highlightFgColorHex = "#080709"
borderColorHex      = "#614e6e"
matchFgColorHex     = "#b657ff"

[[themes]]
name                = "Legacy"
bgColorHex          = "#14191f"
fgColorHex          = "#aec2e0"
highlightBgColorHex = "#1b232c"
highlightFgColorHex = "#aec2e0"
borderColorHex      = "#324357"
matchFgColorHex     = ""

[[themes]]
name                = "Material Dark"
bgColorHex          = "#263238"
fgColorHex          = "#ECEFF1"
highlightBgColorHex = "#FFAB40"
highlightFgColorHex = "#263238"
borderColorHex      = "#37474F"
matchFgColorHex     = ""

[[themes]]
name                = "Material Light"
bgColorHex          = "#FAFAFA"
fgColorHex          = "#212121"
highlightBgColorHex = "#FFAB40"
highlightFgColorHex = "#FAFAFA"
borderColorHex      = "#BDBDBD"
matchFgColorHex     = ""

[[themes]]
name                = "Mellow"
bgColorHex          = "#36312c"
fgColorHex          = "#f8f8f2"
highlightBgColorHex = "#45403b"
highlightFgColorHex = "#36312c"
borderColorHex      = "#7a7267"
matchFgColorHex     = "#1f8181"

[[themes]]
name                = "Mellow Contrast"
bgColorHex          = "#0b0a09"
fgColorHex          = "#f8f8f2"
highlightBgColorHex = "#13110f"
highlightFgColorHex = "#0b0a09"
borderColorHex      = "#7a7267"
matchFgColorHex     = "#1f8181"

[[themes]]
name                = "Mintchoc"
bgColorHex          = "#2b221c"
fgColorHex          = "#bababa"
highlightBgColorHex = "#3f322a"
highlightFgColorHex = "#2b221c"
borderColorHex      = "#564439"
matchFgColorHex     = "#008d62"

[[themes]]
name                = "Monokai"
bgColorHex          = "#272822"
fgColorHex          = "#F8F8F2"
highlightBgColorHex = "#66D9EF"
highlightFgColorHex = "#272822"
borderColorHex      = "#49483E"
matchFgColorHex     = ""

[[themes]]
name                = "Monokai Pro"
bgColorHex          = "#2D2A2E"
fgColorHex          = "#FCFCFA"
highlightBgColorHex = "#78DCE8"
highlightFgColorHex = "#2D2A2E"
borderColorHex      = "#5B595C"
matchFgColorHex     = ""

[[themes]]
name                = "Mud"
bgColorHex          = "#403635"
fgColorHex          = "#ffffff"
highlightBgColorHex = "#322a29"
highlightFgColorHex = "#403635"
borderColorHex      = "#c3b8b7"
matchFgColorHex     = "#ff9787"

[[themes]]
name                = "Mud Contrast"
bgColorHex          = "#0d0b0b"
fgColorHex          = "#ffffff"
highlightBgColorHex = "#171413"
highlightFgColorHex = "#0d0b0b"
borderColorHex      = "#524343"
matchFgColorHex     = "#f55239"

[[themes]]
name                = "Nord"
bgColorHex          = "#2E3440"
fgColorHex          = "#D8DEE9"
highlightBgColorHex = "#88C0D0"
highlightFgColorHex = "#2E3440"
borderColorHex      = "#4C566A"
matchFgColorHex     = ""

[[themes]]
name                = "One Dark"
bgColorHex          = "#282C34"
fgColorHex          = "#ABB2BF"
highlightBgColorHex = "#61AFEF"
highlightFgColorHex = "#282C34"
borderColorHex      = "#3E4451"
matchFgColorHex     = ""

[[themes]]
name                = "One Light"
bgColorHex          = "#FAFAFA"
fgColorHex          = "#383A42"
highlightBgColorHex = "#4078F2"
highlightFgColorHex = "#FAFAFA"
borderColorHex      = "#E5E5E6"
matchFgColorHex     = ""

[[themes]]
name                = "Otakon"
bgColorHex          = "#171417"
fgColorHex          = "#f9f3f9"
highlightBgColorHex = "#332d33"
highlightFgColorHex = "#171417"
borderColorHex      = "#515166"
matchFgColorHex     = "#f6e6eb"

[[themes]]
name                = "Palenight"
bgColorHex          = "#292D3E"
fgColorHex          = "#EEFFFF"
highlightBgColorHex = "#82AAFF"
highlightFgColorHex = "#292D3E"
borderColorHex      = "#444267"
matchFgColorHex     = ""

[[themes]]
name                = "Pastel"
bgColorHex          = "#222222"
fgColorHex          = "#eeeeee"
highlightBgColorHex = "#333333"
highlightFgColorHex = "#222222"
borderColorHex      = "#444444"
matchFgColorHex     = "#04c4a5"

[[themes]]
name                = "Patriot"
bgColorHex          = "#2d3133"
fgColorHex          = "#cad9e3"
highlightBgColorHex = "#40484d"
highlightFgColorHex = "#2d3133"
borderColorHex      = "#515e66"
matchFgColorHex     = "#2e6fd9"

[[themes]]
name                = "Patriot Contrast"
bgColorHex          = "#0d0e0f"
fgColorHex          = "#cad9e3"
highlightBgColorHex = "#191b1c"
highlightFgColorHex = "#0d0e0f"
borderColorHex      = "#515e66"
matchFgColorHex     = "#2e6fd9"

[[themes]]
name                = "Peacock"
bgColorHex          = "#2b2a27"
fgColorHex          = "#ede0ce"
highlightBgColorHex = "#403c37"
highlightFgColorHex = "#2b2a27"
borderColorHex      = "#7a7267"
matchFgColorHex     = "#ff5d38"

[[themes]]
name                = "Peacock Contrast"
bgColorHex          = "#0c0c0b"
fgColorHex          = "#ffffff"
highlightBgColorHex = "#151513"
highlightFgColorHex = "#0c0c0b"
borderColorHex      = "#555555"
matchFgColorHex     = "#ff5d38"

[[themes]]
name                = "Peacocks In Space"
bgColorHex          = "#2b303b"
fgColorHex          = "#dee3ec"
highlightBgColorHex = "#272b34"
highlightFgColorHex = "#2b303b"
borderColorHex      = "#6e7a94"
matchFgColorHex     = "#ff5d38"

[[themes]]
name                = "Peel"
bgColorHex          = "#23201c"
fgColorHex          = "#edebe6"
highlightBgColorHex = "#403c37"
highlightFgColorHex = "#23201c"
borderColorHex      = "#585146"
matchFgColorHex     = "#d3643b"

[[themes]]
name                = "Piggy"
bgColorHex          = "#1c1618"
fgColorHex          = "#edebe6"
highlightBgColorHex = "#34282c"
highlightFgColorHex = "#1c1618"
borderColorHex      = "#3f3236"
matchFgColorHex     = "#fd6a5d"

[[themes]]
name                = "Potpourri"
bgColorHex          = "#2e2b2c"
fgColorHex          = "#f8f8f2"
highlightBgColorHex = "#403c37"
highlightFgColorHex = "#2e2b2c"
borderColorHex      = "#696363"
matchFgColorHex     = "#ed1153"

[[themes]]
name                = "Potpourri Contrast"
bgColorHex          = "#0d0c0c"
fgColorHex          = "#f8f8f2"
highlightBgColorHex = "#141313"
highlightFgColorHex = "#0d0c0c"
borderColorHex      = "#696363"
matchFgColorHex     = "#ed1153"

[[themes]]
name                = "Rainbow"
bgColorHex          = "#16181a"
fgColorHex          = "#c7d0d9"
highlightBgColorHex = "#403c37"
highlightFgColorHex = "#16181a"
borderColorHex      = "#424c55"
matchFgColorHex     = "#ef746f"

[[themes]]
name                = "Revelation"
bgColorHex          = "#2e2c2b"
fgColorHex          = "#dedede"
highlightBgColorHex = "#3b3633"
highlightFgColorHex = "#2e2c2b"
borderColorHex      = "#7b726b"
matchFgColorHex     = "#617fa0"

[[themes]]
name                = "Revelation Contrast"
bgColorHex          = "#0c0b0b"
fgColorHex          = "#dedede"
highlightBgColorHex = "#1a1918"
highlightFgColorHex = "#0c0b0b"
borderColorHex      = "#7b726b"
matchFgColorHex     = "#617fa0"

[[themes]]
name                = "Shrek"
bgColorHex          = "#222222"
fgColorHex          = "#ffffff"
highlightBgColorHex = "#333333"
highlightFgColorHex = "#222222"
borderColorHex      = "#555555"
matchFgColorHex     = "#857a5e"

[[themes]]
name                = "Slate"
bgColorHex          = "#19191f"
fgColorHex          = "#ebebf4"
highlightBgColorHex = "#2a2a33"
highlightFgColorHex = "#19191f"
borderColorHex      = "#515166"
matchFgColorHex     = "#89a7b1"

[[themes]]
name                = "Slime"
bgColorHex          = "#292d30"
fgColorHex          = "#ffffff"
highlightBgColorHex = "#384147"
highlightFgColorHex = "#292d30"
borderColorHex      = "#4f5a63"
matchFgColorHex     = "#9fb3c2"

[[themes]]
name                = "Slime Contrast"
bgColorHex          = "#0b0c0d"
fgColorHex          = "#ffffff"
highlightBgColorHex = "#131516"
highlightFgColorHex = "#0b0c0d"
borderColorHex      = "#4f5a63"
matchFgColorHex     = "#6a9ec5"

[[themes]]
name                = "Snappy"
bgColorHex          = "#393939"
fgColorHex          = "#e3e2e0"
highlightBgColorHex = "#282828"
highlightFgColorHex = "#393939"
borderColorHex      = "#696969"
matchFgColorHex     = "#f66153"

[[themes]]
name                = "Snappy Contrast"
bgColorHex          = "#0c0c0c"
fgColorHex          = "#e3e2e0"
highlightBgColorHex = "#181818"
highlightFgColorHex = "#0c0c0c"
borderColorHex      = "#696969"
matchFgColorHex     = "#f66153"

[[themes]]
name                = "Snappy Light"
bgColorHex          = "#ffffff"
fgColorHex          = "#555555"
highlightBgColorHex = "#eeeeee"
highlightFgColorHex = "#ffffff"
borderColorHex      = "#bbbbbb"
matchFgColorHex     = "#f66153"

[[themes]]
name                = "Solarflare"
bgColorHex          = "#222222"
fgColorHex          = "#e3e2e0"
highlightBgColorHex = "#282828"
highlightFgColorHex = "#222222"
borderColorHex      = "#777777"
matchFgColorHex     = "#ff4e50"

[[themes]]
name                = "Solarflare Contrast"
bgColorHex          = "#000000"
fgColorHex          = "#e3e2e0"
highlightBgColorHex = "#151515"
highlightFgColorHex = "#000000"
borderColorHex      = "#777777"
matchFgColorHex     = "#ff4e50"

[[themes]]
name                = "Solarized Dark"
bgColorHex          = "#002B36"
fgColorHex          = "#839496"
highlightBgColorHex = "#268BD2"
highlightFgColorHex = "#002B36"
borderColorHex      = "#073642"
matchFgColorHex     = ""

[[themes]]
name                = "Solarized Light"
bgColorHex          = "#FDF6E3"
fgColorHex          = "#657B83"
highlightBgColorHex = "#268BD2"
highlightFgColorHex = "#FDF6E3"
borderColorHex      = "#EEE8D5"
matchFgColorHex     = ""

[[themes]]
name                = "Sourlick"
bgColorHex          = "#2e2c2b"
fgColorHex          = "#dedede"
highlightBgColorHex = "#3b3633"
highlightFgColorHex = "#2e2c2b"
borderColorHex      = "#615953"
matchFgColorHex     = "#8ac27a"

[[themes]]
name                = "Sourlick Contrast"
bgColorHex          = "#060606"
fgColorHex          = "#dedede"
highlightBgColorHex = "#171615"
highlightFgColorHex = "#060606"
borderColorHex      = "#615953"
matchFgColorHex     = "#8ac27a"

[[themes]]
name                = "Spearmint"
bgColorHex          = "#e1f0ee"
fgColorHex          = "#719692"
highlightBgColorHex = "#ceebe7"
highlightFgColorHex = "#e1f0ee"
borderColorHex      = "#93c7c0"
matchFgColorHex     = "#25808a"

[[themes]]
name                = "Stark"
bgColorHex          = "#2e2c2b"
fgColorHex          = "#dedede"
highlightBgColorHex = "#3b3633"
highlightFgColorHex = "#2e2c2b"
borderColorHex      = "#615953"
matchFgColorHex     = "#f03113"

[[themes]]
name                = "Stark Contrast"
bgColorHex          = "#0b0a0a"
fgColorHex          = "#dedede"
highlightBgColorHex = "#181716"
highlightFgColorHex = "#0b0a0a"
borderColorHex      = "#615953"
matchFgColorHex     = "#f03113"

[[themes]]
name                = "Super"
bgColorHex          = "#15191d"
fgColorHex          = "#ffffff"
highlightBgColorHex = "#242b32"
highlightFgColorHex = "#15191d"
borderColorHex      = "#465360"
matchFgColorHex     = "#d60257"

[[themes]]
name                = "Synthwave 84"
bgColorHex          = "#2A2139"
fgColorHex          = "#FFFFFF"
highlightBgColorHex = "#F92AAD"
highlightFgColorHex = "#2A2139"
borderColorHex      = "#495495"
matchFgColorHex     = ""

[[themes]]
name                = "Tokyo Night"
bgColorHex          = "#1A1B26"
fgColorHex          = "#A9B1D6"
highlightBgColorHex = "#7AA2F7"
highlightFgColorHex = "#1A1B26"
borderColorHex      = "#32344A"
matchFgColorHex     = ""

[[themes]]
name                = "Tokyo Night Light"
bgColorHex          = "#D5D6DB"
fgColorHex          = "#343B58"
highlightBgColorHex = "#34548A"
highlightFgColorHex = "#D5D6DB"
borderColorHex      = "#CBCCD1"
matchFgColorHex     = ""

[[themes]]
name                = "Tonic"
bgColorHex          = "#2a2f31"
fgColorHex          = "#eeeeee"
highlightBgColorHex = "#353b3e"
highlightFgColorHex = "#2a2f31"
borderColorHex      = "#4a5356"
matchFgColorHex     = "#b8cd44"

[[themes]]
name                = "Tribal"
bgColorHex          = "#19191d"
fgColorHex          = "#ffffff"
highlightBgColorHex = "#33333c"
highlightFgColorHex = "#19191d"
borderColorHex      = "#4a4a54"
matchFgColorHex     = "#5f5582"

[[themes]]
name                = "Tron"
bgColorHex          = "#14191f"
fgColorHex          = "#aec2e0"
highlightBgColorHex = "#1b232c"
highlightFgColorHex = "#14191f"
borderColorHex      = "#324357"
matchFgColorHex     = "#ffffff"

[[themes]]
name                = "Tron Contrast"
bgColorHex          = "#07090b"
fgColorHex          = "#aec2e0"
highlightBgColorHex = "#101419"
highlightFgColorHex = "#07090b"
borderColorHex      = "#324357"
matchFgColorHex     = "#ffffff"

[[themes]]
name                = "Turnip"
bgColorHex          = "#1a1b1d"
fgColorHex          = "#ede0ce"
highlightBgColorHex = "#222222"
highlightFgColorHex = "#1a1b1d"
borderColorHex      = "#7a7267"
matchFgColorHex     = "#487d76"

[[themes]]
name                = "Turnip Contrast"
bgColorHex          = "#080809"
fgColorHex          = "#ede0ce"
highlightBgColorHex = "#1c1d1f"
highlightFgColorHex = "#080809"
borderColorHex      = "#7a7267"
matchFgColorHex     = "#487d76"

[[themes]]
name                = "Userscape"
bgColorHex          = "#f5f8fc"
fgColorHex          = "#879bb0"
highlightBgColorHex = "#eeeeee"
highlightFgColorHex = "#f5f8fc"
borderColorHex      = "#bbbbbb"
matchFgColorHex     = "#355b8c"

[[themes]]
name                = "Yule"
bgColorHex          = "#2b2a27"
fgColorHex          = "#ede0ce"
highlightBgColorHex = "#52504b"
highlightFgColorHex = "#2b2a27"
borderColorHex      = "#7a7267"
matchFgColorHex     = "#d63131"

[[themes]]
name                = "Zacks"
bgColorHex          = "#222222"
fgColorHex          = "#f0f0f0"
highlightBgColorHex = "#333333"
highlightFgColorHex = "#222222"
borderColorHex      = "#777777"
matchFgColorHex     = "#ff6a38"

[[themes]]
name                = "Zacks Contrast"
bgColorHex          = "#000000"
fgColorHex          = "#f0f0f0"
highlightBgColorHex = "#151515"
highlightFgColorHex = "#000000"
borderColorHex      = "#777777"
matchFgColorHex     = "#ff6a38"

# remember last used
[theme]
last_chosen = "Default"
"""
