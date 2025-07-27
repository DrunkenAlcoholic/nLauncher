# src/state.nim
#
# Centralized global state and data structures for the launcher.

import x11/[xlib, x]

# --- Data Structures ---

type
  DesktopApp* = object ## Represents a launchable application.
    name*: string
    exec*: string
    hasIcon*: bool

  CacheData* = object ## Structure for the cache file.
    usrMtime*: float
    localMtime*: float
    apps*: seq[DesktopApp]

  Config* = object ## User-configurable settings.
    winWidth*, winMaxHeight*, lineHeight*, maxVisibleItems*: int
    centerWindow*: bool
    positionX*, positionY*: int
    verticalAlign*: string
    bgColorHex*, fgColorHex*: string
    highlightBgColorHex*, highlightFgColorHex*: string
    borderColorHex*: string
    prompt*, cursor*: string
    borderWidth*: int
    bgColor*, fgColor*, highlightBgColor*, highlightFgColor*, borderColor*: culong
    themeName*: string
    fontName*: string

# --- Global State Variables ---

var
  # X11 handles
  display*: PDisplay
  window*: Window
  graphicsContext*: GC
  screen*: cint

  # Application state
  config*: Config
  allApps*: seq[DesktopApp]
  filteredApps*: seq[DesktopApp]

  # UI state
  inputText*: string
  selectedIndex*: int
  viewOffset*: int
  shouldExit*: bool
