# src/nim_launcher.nim
#
# The main entry point for the application.
# modules to initialize the launcher, load data, and run the main event loop.

import
  std/
    [os, osproc, strutils, options, tables, sequtils, algorithm, parsecfg, json, times]
import x11/[xlib, xutil, x, keysym]

# Import our custom modules
import state, parser, gui, themes

# --- Data Loading and Caching ---

proc loadApplications() =
  ## Loads the list of applications, using a smart cache to ensure fast startups.
  let homeDir = getHomeDir()
  let usrAppDir = "/usr/share/applications"
  let localAppDir = homeDir / ".local/share/applications"
  let cacheDir = homeDir / ".cache" / "nim_launcher"
  let cacheFile = cacheDir / "apps.json"

  # 1. Get the current modification times of the application source directories.
  var currentUsrMtime = 0.0
  if dirExists(usrAppDir):
    currentUsrMtime = getLastModificationTime(usrAppDir).toUnixFloat()
  var currentLocalMtime = 0.0
  if dirExists(localAppDir):
    currentLocalMtime = getLastModificationTime(localAppDir).toUnixFloat()

  # 2. Check for a valid cache file.
  if fileExists(cacheFile):
    try:
      let content = readFile(cacheFile)
      let cache = to(parseJson(content), CacheData)

      # Validate the cache by comparing directory modification times.
      if cache.usrMtime == currentUsrMtime and cache.localMtime == currentLocalMtime:
        allApps = cache.apps
        filteredApps = allApps
        echo "Loaded ", allApps.len, " applications from cache."
        return # Cache is valid, we're done.
    except JsonParsingError:
      echo "Cache file corrupted (malformed JSON), re-scanning..."
    except ValueError:
      echo "Cache file corrupted (invalid data), re-scanning..."

  # 3. If cache is invalid, perform a full scan using our parser module.
  echo "Cache invalid or missing, scanning for applications..."
  var apps = initTable[string, DesktopApp]()
  let searchPaths = [localAppDir, usrAppDir]
  for basePath in searchPaths:
    if not dirExists(basePath):
      continue
    for path in walkFiles(basePath / "*.desktop"):
      let appOpt = parseDesktopFile(path)
      if appOpt.isSome:
        let newApp = appOpt.get()
        let baseExec = getBaseExec(newApp.exec)
        # De-duplicate applications based on their base command.
        if not apps.hasKey(baseExec):
          apps[baseExec] = newApp
        else:
          # Simple "best wins" logic: prefer entries that have an icon specified.
          let existingApp = apps[baseExec]
          if newApp.hasIcon and not existingApp.hasIcon:
            apps[baseExec] = newApp

  allApps = toSeq(apps.values).sortedByIt(it.name)
  filteredApps = allApps
  echo "Found ", allApps.len, " unique applications."

  # 4. Write the new application list back to the cache for future runs.
  let newCache =
    CacheData(usrMtime: currentUsrMtime, localMtime: currentLocalMtime, apps: allApps)
  try:
    createDir(cacheDir)
    writeFile(cacheFile, pretty(%newCache))
    echo "Saved new application list to cache."
  except:
    echo "Warning: Could not write to cache file at ", cacheFile

# --- Configuration Loading ---

proc initLauncherConfig() =
  ## Loads settings from the config file, creating a default one if it doesn't exist.

  # 1. Set hardcoded defaults first. These will be used if the config file
  #    is missing or if a specific key is not present.
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
  var themeName = ""

  # 2. Define config path and create a default file if necessary.
  let configPath = getHomeDir() / ".config" / "nim_launcher" / "config.ini"
  if not fileExists(configPath):
    let content =
      """
[window]
width = 600
max_visible_items = 15
center = true
position_x = 500
position_y = 50
vertical_align = "one-third" #usage: "one-third", "top", "center"

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

[theme]
# Leaving this empty will use the colour scheme in the [colors] section. 
# or choose one of the inbuilt themes below to override by un-commenting.
#name: "Nord",
#name: "Solarized Dark"
#name: "Solarized Light"
#name: "Gruvbox Dark"
#name: "Gruvbox Light"
#name: "Dracula"
#name: "Monokai"
#name: "One Dark"
#name: "Material Dark"
#name: "Material Light"
#name: "Cobalt"
#name: "Ayu Dark"
#name: "Ayu Light"
#name: "Catppuccin Mocha"
#name: "Catppuccin Latte"
#name: "Catppuccin Frappe"
"""
    try:
      createDir(configPath.parentDir)
      writeFile(configPath, content)
      echo "Created default config at: ", configPath
    except:
      echo "Warning: Could not write default config file at ", configPath

  # 3. If config file exists, load it and overwrite the defaults.
  if fileExists(configPath):
    let cfg = loadConfig(configPath)
    proc parseInt(section, key: string, default: int): int =
      let valStr = cfg.getSectionValue(section, key, $default)
      try:
        return parseInt(valStr)
      except ValueError:
        return default

    config.winWidth = parseInt("window", "width", config.winWidth)
    config.maxVisibleItems =
      parseInt("window", "max_visible_items", config.maxVisibleItems)
    config.centerWindow =
      cfg.getSectionValue("window", "center", $config.centerWindow).toLower == "true"
    config.positionX = parseInt("window", "position_x", config.positionX)
    config.positionY = parseInt("window", "position_y", config.positionY)
    config.verticalAlign =
      cfg.getSectionValue("window", "vertical_align", config.verticalAlign)
    config.bgColorHex = cfg.getSectionValue("colors", "background", config.bgColorHex)
    config.fgColorHex = cfg.getSectionValue("colors", "foreground", config.fgColorHex)
    config.highlightBgColorHex =
      cfg.getSectionValue("colors", "highlight_background", config.highlightBgColorHex)
    config.highlightFgColorHex =
      cfg.getSectionValue("colors", "highlight_foreground", config.highlightFgColorHex)
    config.borderColorHex =
      cfg.getSectionValue("colors", "border_color", config.borderColorHex)
    config.borderWidth = parseInt("border", "width", config.borderWidth)
    config.prompt = cfg.getSectionValue("input", "prompt", config.prompt)
    config.cursor = cfg.getSectionValue("input", "cursor", config.cursor)
    themeName = cfg.getSectionValue("theme", "name", themeName)

  # --- Theme selection logic ---
  for theme in arrthemes:
    if theme.name.toLower == themeName.toLower:
      config.bgColorHex = theme.bgColorHex
      config.fgColorHex = theme.fgColorHex
      config.highlightBgColorHex = theme.highlightBgColorHex
      config.highlightFgColorHex = theme.highlightFgColorHex
      config.borderColorHex = theme.borderColorHex
      break

  # 4. Calculate the final window height based on the loaded (or default) settings.
  let inputHeight = 40
  config.winMaxHeight = inputHeight + (config.maxVisibleItems * config.lineHeight)

# --- Core Application Logic ---

proc fuzzyMatch(query: string, target: string): bool =
  ## Performs a simple, case-insensitive fuzzy match.
  ## Returns true if all characters in `query` appear in `target` in the same order.
  if query.len == 0:
    return true
  var queryIndex = 0
  for char in target.toLower:
    if queryIndex < query.len and query.toLower[queryIndex] == char:
      queryIndex += 1
      if queryIndex == query.len:
        return true
  return false

proc updateFilteredApps() =
  ## Updates the `filteredApps` list based on the current `inputText`.
  filteredApps = allApps.filter(
    proc(app: DesktopApp): bool =
      fuzzyMatch(inputText, app.name)
  )
  selectedIndex = 0
  viewOffset = 0 # Reset scroll on new search

proc launchSelectedApp() =
  ## Launches the currently selected application using the system shell.
  if selectedIndex >= 0 and selectedIndex < filteredApps.len:
    let app = filteredApps[selectedIndex]
    let cleanExec = app.exec.split('%')[0].strip() # Remove field codes like %U
    try:
      echo "Launching via shell: ", cleanExec
      discard startProcess("/bin/sh", args = ["-c", cleanExec], options = {poDaemon})
      shouldExit = true
    except:
      echo "Error launching application via shell: ", cleanExec

proc handleKeyPress(event: var XEvent) =
  ## Processes a key press event from the X server.
  var buffer: array[40, char]
  var keysym: KeySym
  discard XLookupString(
    event.xkey.addr, cast[cstring](buffer[0].addr), cint(buffer.len), keysym.addr, nil
  )

  case keysym
  of XK_Escape:
    shouldExit = true
  of XK_Return:
    launchSelectedApp()
  of XK_BackSpace:
    if inputText.len > 0:
      inputText.setLen(inputText.len - 1)
      updateFilteredApps()
  of XK_Up:
    if selectedIndex > 0:
      selectedIndex -= 1
      # Scroll the view up if the selection goes above the visible area.
      if selectedIndex < viewOffset:
        viewOffset = selectedIndex
  of XK_Down:
    if selectedIndex < filteredApps.len - 1:
      selectedIndex += 1
      # Scroll the view down if the selection goes below the visible area.
      if selectedIndex >= viewOffset + config.maxVisibleItems:
        viewOffset = selectedIndex - config.maxVisibleItems + 1
  else:
    # Handle printable characters.
    if buffer[0] != '\0' and buffer[0] >= ' ':
      inputText.add(buffer[0])
      updateFilteredApps()

# --- Main Program Execution ---

proc main() =
  ## The main entry point of the program.

  # 1. Load settings from the config file (or create one).
  initLauncherConfig()

  # 2. Load the application list (from cache or by scanning).
  loadApplications()

  # 3. Create and display the GUI window.
  initGui()

  # 4. Run the main event loop.
  while not shouldExit:
    var event: XEvent
    discard XNextEvent(display, event.addr)

    case event.theType
    of Expose:
      redrawWindow()
    of KeyPress:
      handleKeyPress(event)
      if not shouldExit: # Avoid a final redraw if we're closing
        redrawWindow()
    of FocusOut:
      # If the window loses focus, exit gracefully.
      echo "Focus lost. Closing."
      shouldExit = true
    else:
      discard

  # 5. Clean up X11 resources before exiting.
  discard XDestroyWindow(display, window)
  discard XCloseDisplay(display)

# Run the program.
main()
