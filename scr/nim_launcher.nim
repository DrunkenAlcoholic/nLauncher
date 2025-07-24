import std/[os, osproc, strutils, options, tables, sequtils, algorithm, parsecfg, json, times]
import x11/[xlib, xutil, x, keysym]
import state, parser, gui

proc loadApplications() =
  let homeDir = getHomeDir()
  let usrAppDir = "/usr/share/applications"
  let localAppDir = homeDir / ".local/share/applications"
  let cacheDir = homeDir / ".cache" / "nim_launcher"
  let cacheFile = cacheDir / "apps.json"

  var currentUsrMtime = 0.0
  if dirExists(usrAppDir):
    currentUsrMtime = getLastModificationTime(usrAppDir).toUnixFloat()
  var currentLocalMtime = 0.0
  if dirExists(localAppDir):
    currentLocalMtime = getLastModificationTime(localAppDir).toUnixFloat()

  if fileExists(cacheFile):
    try:
      let content = readFile(cacheFile)
      let cache = to(parseJson(content), CacheData)
      
      if cache.usrMtime == currentUsrMtime and cache.localMtime == currentLocalMtime:
        allApps = cache.apps
        filteredApps = allApps
        echo "Loaded ", allApps.len, " applications from cache."
        return
    # --- THE FIX IS HERE ---
    except JsonParsingError:
      echo "Cache file corrupted (malformed JSON), re-scanning..."
    except ValueError:
      echo "Cache file corrupted (invalid data), re-scanning..."
  
  echo "Cache invalid or missing, scanning for applications..."
  var apps = initTable[string, DesktopApp]()
  let searchPaths = [localAppDir, usrAppDir]
  for basePath in searchPaths:
    if not dirExists(basePath): continue
    for path in walkFiles(basePath / "*.desktop"):
      let appOpt = parseDesktopFile(path)
      if appOpt.isSome:
        let newApp = appOpt.get()
        let baseExec = getBaseExec(newApp.exec)
        if not apps.hasKey(baseExec):
          apps[baseExec] = newApp
        else:
          let existingApp = apps[baseExec]
          if newApp.hasIcon and not existingApp.hasIcon:
            apps[baseExec] = newApp
  
  allApps = toSeq(apps.values).sortedByIt(it.name)
  filteredApps = allApps
  echo "Found ", allApps.len, " unique applications."

  let newCache = CacheData(
    usrMtime: currentUsrMtime,
    localMtime: currentLocalMtime,
    apps: allApps
  )
  try:
    createDir(cacheDir)
    writeFile(cacheFile, pretty(%newCache))
    echo "Saved new application list to cache."
  except:
    echo "Warning: Could not write to cache file at ", cacheFile

# --- The rest of the file is completely unchanged ---
# ... (initLauncherConfig, fuzzyMatch, all GUI code, etc. is the same) ...
proc initLauncherConfig() =
  # 1. Set hardcoded defaults first
  config.winWidth = 600
  config.lineHeight = 22
  config.maxVisibleItems = 15
  config.centerWindow = true
  config.positionX = 500
  config.positionY = 50
  config.verticalAlign = "one-third"
  config.bgColorHex = "#2E3440"
  config.fgColorHex = "#D8DEE9"
  config.highlightBgColorHex = "#88C0D0"
  config.highlightFgColorHex = "#2E3440"
  config.borderColorHex = "#4C566A"
  config.borderWidth = 2
  config.prompt = "> "
  config.cursor = "_"

  # 2. Check for and load the real config file
  let configPath = getHomeDir() / ".config" / "nim_launcher" / "config.ini"
  if not fileExists(configPath):
    let content = """
[window]
width = 600
max_visible_items = 15
center = true
position_x = 500
position_y = 50
vertical_align = "one-third"

[colors]
background = "#2E3440"
foreground = "#D8DEE9"
highlight_background = "#88C0D0"
highlight_foreground = "#2E3440"
border_color = "#4C566A"

[border]
width = 2

[input]
prompt = "> "
cursor = "_"
"""
    try:
      createDir(configPath.parentDir)
      writeFile(configPath, content)
      echo "Created default config at: ", configPath
    except:
      echo "Warning: Could not write default config file at ", configPath

  if fileExists(configPath):
    let cfg = loadConfig(configPath)
    proc parseInt(section, key: string, default: int): int =
      let valStr = cfg.getSectionValue(section, key, $default)
      try:
        return parseInt(valStr)
      except ValueError:
        return default

    config.winWidth = parseInt("window", "width", config.winWidth)
    config.maxVisibleItems = parseInt("window", "max_visible_items", config.maxVisibleItems)
    config.centerWindow = cfg.getSectionValue("window", "center", $config.centerWindow).toLower == "true"
    config.positionX = parseInt("window", "position_x", config.positionX)
    config.positionY = parseInt("window", "position_y", config.positionY)
    config.verticalAlign = cfg.getSectionValue("window", "vertical_align", config.verticalAlign)
    config.bgColorHex = cfg.getSectionValue("colors", "background", config.bgColorHex)
    config.fgColorHex = cfg.getSectionValue("colors", "foreground", config.fgColorHex)
    config.highlightBgColorHex = cfg.getSectionValue("colors", "highlight_background", config.highlightBgColorHex)
    config.highlightFgColorHex = cfg.getSectionValue("colors", "highlight_foreground", config.highlightFgColorHex)
    config.borderColorHex = cfg.getSectionValue("colors", "border_color", config.borderColorHex)
    config.borderWidth = parseInt("border", "width", config.borderWidth)
    config.prompt = cfg.getSectionValue("input", "prompt", config.prompt)
    config.cursor = cfg.getSectionValue("input", "cursor", config.cursor)

  # 4. Calculate final height
  let inputHeight = 40
  config.winMaxHeight = inputHeight + (config.maxVisibleItems * config.lineHeight)

proc fuzzyMatch(query: string, target: string): bool =
  if query.len == 0: return true
  var queryIndex = 0
  for char in target.toLower:
    if queryIndex < query.len and query.toLower[queryIndex] == char:
      queryIndex += 1
      if queryIndex == query.len: return true
  return false

proc updateFilteredApps() =
  filteredApps = allApps.filter(proc (app: DesktopApp): bool = fuzzyMatch(inputText, app.name))
  selectedIndex = 0
  viewOffset = 0

proc launchSelectedApp() =
  if selectedIndex >= 0 and selectedIndex < filteredApps.len:
    let app = filteredApps[selectedIndex]
    let cleanExec = app.exec.split('%')[0].strip()
    try:
      echo "Launching via shell: ", cleanExec
      discard startProcess("/bin/sh", args = ["-c", cleanExec], options = {poDaemon})
      shouldExit = true
    except:
      echo "Error launching application via shell: ", cleanExec


proc handleKeyPress(event: var XEvent) =
  var buffer: array[40, char]
  var keysym: KeySym
  discard XLookupString(event.xkey.addr, cast[cstring](buffer[0].addr), cint(buffer.len), keysym.addr, nil)
  case keysym
  of XK_Escape: shouldExit = true
  of XK_Return: launchSelectedApp()
  of XK_BackSpace:
    if inputText.len > 0:
      inputText.setLen(inputText.len - 1)
      updateFilteredApps()
  of XK_Up:
    if selectedIndex > 0:
      selectedIndex -= 1
      if selectedIndex < viewOffset:
        viewOffset = selectedIndex
  of XK_Down:
    if selectedIndex < filteredApps.len - 1:
      selectedIndex += 1
      if selectedIndex >= viewOffset + config.maxVisibleItems:
        viewOffset = selectedIndex - config.maxVisibleItems + 1
  else:
    if buffer[0] != '\0' and buffer[0] >= ' ':
      inputText.add(buffer[0])
      updateFilteredApps()

proc main() =
  initLauncherConfig()
  loadApplications()
  initGui()
  
  while not shouldExit:
    var event: XEvent
    discard XNextEvent(display, event.addr)
    
    case event.theType
    of Expose: redrawWindow()
    of KeyPress:
      handleKeyPress(event)
      if not shouldExit:
        redrawWindow()
    of FocusOut:
      echo "Focus lost. Closing."
      shouldExit = true
    else: discard
  
  discard XDestroyWindow(display, window)
  discard XCloseDisplay(display)

main()
