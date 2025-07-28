#──────────────────────────────────────────────────────────────────────────────
#  state.nim — Centralized data definitions & global runtime state
#──────────────────────────────────────────────────────────────────────────────
# This module defines:
#   - Types for app metadata, config, and launcher state
#   - Global mutable state used throughout the launcher
#   - Constants including terminal fallbacks and config template
#
# IMPORTANT: This file is intentionally logic-free to avoid circular dependencies.
# Only use it to define types, constants, and global vars.

import x11/[xlib, x]

#──────────────────────────────────────────────────────────────────────────────
#  Data Types
#──────────────────────────────────────────────────────────────────────────────

type
  ## One entry in the application list.
  DesktopApp* = object
    name*, exec*: string
    hasIcon*: bool              ## True if the .desktop file had an Icon= entry

  ## Cached app list and mtimes for /usr and ~/.local launchers
  CacheData* = object
    usrMtime*, localMtime*: int64
    apps*: seq[DesktopApp]

  ## Runtime configuration object populated by initLauncherConfig()
  Config* = object
    # ─ Window geometry
    winWidth*, winMaxHeight*: int
    lineHeight*, maxVisibleItems*: int
    centerWindow*: bool
    positionX*, positionY*: int
    verticalAlign*: string          ## "top", "center", or "one-third"

    # ─ Colors (hex strings from INI)
    bgColorHex*, fgColorHex*: string
    highlightBgColorHex*, highlightFgColorHex*: string
    borderColorHex*: string
    borderWidth*: int

    # ─ Fonts / prompt / terminal
    prompt*, cursor*: string
    fontName*: string
    themeName*: string
    terminalExe*: string

    # ─ Parsed Xft/X11 colors (populated at runtime)
    bgColor*, fgColor*, highlightBgColor*, highlightFgColor*, borderColor*: culong

  ## Input interpretation mode based on prefix
  InputMode* = enum
    imNormal,         ## Default app search
    imRunCommand,     ## `/...` → direct command
    imConfigSearch,   ## `/c ...` → match ~/.config
    imYouTube,        ## `/y ...` → open YouTube search
    imGoogle,         ## `/g ...` → open Google search
    imWiki            ## `/w ...` → open Wikipedia search

#──────────────────────────────────────────────────────────────────────────────
#  Global X11 handles
#──────────────────────────────────────────────────────────────────────────────

var
  display*: PDisplay
  window*: Window
  gc*: GC
  screen*: cint

#──────────────────────────────────────────────────────────────────────────────
#  Global launcher runtime state
#──────────────────────────────────────────────────────────────────────────────

var
  config*: Config
  inputMode*: InputMode = imNormal

  allApps*, filteredApps*: seq[DesktopApp]
  inputText*: string
  selectedIndex*, viewOffset*: int
  shouldExit*: bool
  recentApps*: seq[string]            ## Most recently launched apps
  benchMode*: bool = false            ## Set true with --bench flag

#──────────────────────────────────────────────────────────────────────────────
#  Constants
#──────────────────────────────────────────────────────────────────────────────

const
  maxRecent* = 10

  ## Hard-coded fallback terminal list (used if config & $TERMINAL are empty)
  fallbackTerms* = [
    "kitty", "alacritty", "wezterm", "foot",
    "gnome-terminal", "konsole", "xfce4-terminal", "xterm",
  ]

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
# Or choose a built-in theme:
#name = "Ayu Dark"
#name = "Catppuccin Mocha"
#name = "Dracula"
#name = "Gruvbox Dark"
#name = "Nord"
#name = "One Dark"
"""
