# scr/state.nim
#
# Defines all shared data structures and global state variables for the application.
# By centralizing state here, other modules can import just what they need and
# avoid circular dependencies.

import x11/[xlib, x]
#import sequtils, tables # Required for seq and Table types if used in this module

# --- Data Structures ---

type
  DesktopApp* = object
    ## Represents a single, launchable application found on the system.
    name*: string      # The display name of the application (e.g., "Firefox")
    exec*: string      # The command used to run the application.
    hasIcon*: bool     # Whether the .desktop file specified an icon.

  CacheData* = object
    ## The structure of our cache file (`~/.cache/nim_launcher/apps.json`).
    ## Holds the application list and the modification times for validation.
    usrMtime*: float
    localMtime*: float
    apps*: seq[DesktopApp]

  Config* = object
    ## Holds all user-configurable settings, loaded from `config.ini`.
    # Window settings
    winWidth*: int
    winMaxHeight*: int
    lineHeight*: int
    maxVisibleItems*: int
    centerWindow*: bool
    positionX*, positionY*: int
    verticalAlign*: string
    # Color settings (read from config as hex strings)
    bgColorHex*, fgColorHex*: string
    highlightBgColorHex*, highlightFgColorHex*: string
    borderColorHex*: string
    # Input field settings
    prompt*, cursor*: string
    # Border settings
    borderWidth*: int
    # Populated at runtime from the hex codes above.
    bgColor*, fgColor*, highlightBgColor*, highlightFgColor*, borderColor*: culong

# --- Global State Variables ---

var
  # -- X11 Handles --
  # These are low-level pointers/handles to the X server connection and window.
  display*: PDisplay
  window*: Window
  graphicsContext*: GC
  screen*: cint

  # -- Application State --
  config*: Config                        # The currently loaded configuration.
  allApps*: seq[DesktopApp]             # The master list of all found applications.
  filteredApps*: seq[DesktopApp]        # The list of apps currently visible after fuzzy searching.

  # -- UI State --
  # These variables track the immediate state of the user interface.
  inputText*: string                    # The text the user has currently typed.
  selectedIndex*: int                   # The index of the currently highlighted item in `filteredApps`.
  viewOffset*: int                      # The index of the item at the top of the visible list (for scrolling).
  shouldExit*: bool                     # A flag that signals the main loop to terminate.
