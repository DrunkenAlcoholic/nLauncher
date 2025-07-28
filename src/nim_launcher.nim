#──────────────────────────────────────────────────────────────────────────────
#  nim_launcher.nim — Main Entrypoint for nim_launcher
#──────────────────────────────────────────────────────────────────────────────

import
  std/[os, osproc, strutils, options, tables, sequtils, algorithm, json, times,
       editdistance, sets]
from std/parsecfg import CfgParser, open, next
import x11/[xlib, xutil, x, keysym]
from std/uri import encodeUrl
import state except Config
import parser, gui, themes, utils

type
  LauncherConfig = state.Config

#──────────────────────────────────────────────────────────────────────────────
#  Globals
#──────────────────────────────────────────────────────────────────────────────

var currentThemeIndex = 0 ## Active index into built-in theme list

#──────────────────────────────────────────────────────────────────────────────
#  Main Program Logic
#──────────────────────────────────────────────────────────────────────────────

proc setFromIni(section, key, value: string) =
  if section == "terminal" and key == "program":
    config.terminalExe = value
  elif section == "input":
    if key == "prompt":
      config.prompt = value
    elif key == "cursor":
      config.cursor = value
  elif section == "theme" and key == "name":
    config.themeName = value
  elif section == "font" and key == "fontname":
    config.fontName = value
  elif section == "colors":
    case key
    of "background": config.bgColorHex = value
    of "foreground": config.fgColorHex = value
    of "highlight_background": config.highlightBgColorHex = value
    of "highlight_foreground": config.highlightFgColorHex = value
    of "border_color": config.borderColorHex = value
  elif section == "border" and key == "width":
    config.borderWidth = parseInt(value)
  elif section == "window":
    case key
    of "width": config.winWidth = parseInt(value)
    of "max_visible_items": config.maxVisibleItems = parseInt(value)
    of "center": config.centerWindow = (value.toLowerAscii() == "true")
    of "position_x": config.positionX = parseInt(value)
    of "position_y": config.positionY = parseInt(value)
    of "vertical_align": config.verticalAlign = value

proc getLaunchCommand(query: string): string =
  if query.startsWith("/g "):
    return "xdg-open https://www.google.com/search?q=" & encodeUrl(query[3..^1])
  elif query.startsWith("/y "):
    return "xdg-open https://www.youtube.com/results?search_query=" & encodeUrl(query[3..^1])
  elif query.startsWith("/w "):
    return "xdg-open https://en.wikipedia.org/wiki/" & encodeUrl(query[3..^1])
  elif query.startsWith("/c "):
    return "xdg-open ~/.config/" & encodeUrl(query[3..^1])
  else:
    return query[1..^1]

proc runCommand(cmd: string) =
  let term = chooseTerminal()
  if term.len > 0:
    discard startProcess("/usr/bin/env", args = [term, "-e", "sh", "-c", cmd], options = {poDaemon})
  else:
    discard startProcess("/bin/sh", args = ["-c", cmd], options = {poDaemon})

proc cycleTheme(forward = true) =
  if forward:
    inc currentThemeIndex
    if currentThemeIndex >= themeList.len:
      currentThemeIndex = 0
  else:
    dec currentThemeIndex
    if currentThemeIndex < 0:
      currentThemeIndex = themeList.len - 1
  let t = themeList[currentThemeIndex]
  config.themeName = t.name
  gui.updateGuiColors()
  gui.notifyThemeChanged(t.name)
  redrawWindow()

proc initLauncherConfig() =
  config = LauncherConfig(
    winWidth: 500,
    maxVisibleItems: 10,
    centerWindow: true,
    positionX: 0,
    positionY: 0,
    verticalAlign: "center",
    prompt: "> ",
    cursor: "_",
    fontName: "monospace:size=12",
    borderWidth: 2,
    terminalExe: ""
  )

  let configPath = getConfigDir() / "nim_launcher" / "config.ini"
  if not fileExists(configPath):
    createDir(configPath.parentDir)
    writeFile(configPath, state.iniTemplate)

  var p: CfgParser
  open(p, configPath)
  var currentSection = ""
  while true:
    let e = next(p)
    case e.kind
    of cfgSectionStart:
      currentSection = e.section
    of cfgKeyValuePair:
      setFromIni(currentSection, e.key, e.value)
    of cfgEof:
      break
    of cfgError:
      echo "INI parse error: ", e.msg

  let theme = themeByName(config.themeName)
  config.bgColorHex = theme.bgColorHex
  config.fgColorHex = theme.fgColorHex
  config.highlightBgColorHex = theme.highlightBgColorHex
  config.highlightFgColorHex = theme.highlightFgColorHex
  config.borderColorHex = theme.borderColorHex

proc loadApplications() =
  let paths = [
    "/usr/share/applications",
    getHomeDir() / ".local/share/applications"
  ]
  for path in paths:
    for f in walkDirRec(path, yieldFilter = {pcFile}):
      if f.endsWith(".desktop"):
        let oaOpt = parseDesktopFile(f)
        if oaOpt.isSome:
          allApps.add oaOpt.get

  filteredApps = allApps

#──────────────────────────────────────────────────────────────────────────────
#  Main Execution
#──────────────────────────────────────────────────────────────────────────────

when isMainModule:
  initLauncherConfig()
  loadRecent()
  loadApplications()
  gui.initWindow()
  gui.runEventLoop()
  saveRecent()
