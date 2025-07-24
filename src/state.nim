# src/state.nim
import x11/[xlib, x] 

type
  DesktopApp* = object # Add '*' to export the type
    name*: string
    exec*: string
    hasIcon*: bool
  
  CacheData* = object
    usrMtime*: float
    localMtime*: float
    apps*: seq[DesktopApp]

  Config* = object
    winWidth*: int
    winMaxHeight*: int
    lineHeight*: int
    maxVisibleItems*: int
    centerWindow*: bool
    positionX*, positionY*: int
    verticalAlign*: string
    bgColorHex*, fgColorHex*: string
    highlightBgColorHex*, highlightFgColorHex*: string
    borderColorHex*: string
    prompt*, cursor*: string
    borderWidth*: int
    bgColor*, fgColor*, highlightBgColor*, highlightFgColor*, borderColor*: culong

# --- Global State Variables ---
var
  display*: PDisplay # Add '*' to export the variable
  window*: Window
  graphicsContext*: GC
  screen*: cint
  config*: Config
  allApps*, filteredApps*: seq[DesktopApp]
  inputText*: string
  selectedIndex*, viewOffset*: int
  shouldExit*: bool
