import
  os,
  osproc,
  strutils,
  streams,
  options,
  tables,
  sequtils,
  algorithm,
  std/parsecfg,
  x11/xlib,
  x11/xutil,
  x11/x,
  x11/keysym

# --- Data Structures (Unchanged) ---
type
  DesktopApp = object
    name: string
    exec: string
    hasIcon: bool
  
  Config = object
    winWidth: int
    winMaxHeight: int
    lineHeight: int
    maxVisibleItems: int
    centerWindow: bool
    positionX, positionY: int
    verticalAlign: string
    bgColorHex, fgColorHex: string
    highlightBgColorHex, highlightFgColorHex: string
    borderColorHex: string
    prompt: string
    cursor: string
    borderWidth: int
    bgColor, fgColor, highlightBgColor, highlightFgColor, borderColor: culong

# --- Global State Variables (Unchanged) ---
var
  display: PDisplay
  window: Window
  graphicsContext: GC
  screen: cint
  config: Config
  allApps, filteredApps: seq[DesktopApp] = @[]
  inputText = ""
  selectedIndex = 0
  viewOffset = 0
  shouldExit = false

# --- Data Sourcing Logic ---
proc getBaseExec(exec: string): string = # (Unchanged)
  let cleanExec = exec.split('%')[0].strip()
  return cleanExec.split(' ')[0].extractFilename()

# --- THIS IS THE NEW, PROVEN PARSING LOGIC FROM OUR TESTER ---
proc getBestValue(entries: Table[string, string], baseKey: string): string =
  if entries.hasKey(baseKey): return entries[baseKey]
  if entries.hasKey(baseKey & "[en_US]"): return entries[baseKey & "[en_US]"]
  if entries.hasKey(baseKey & "[en]"): return entries[baseKey & "[en]"]
  for key, val in entries:
    if key.startsWith(baseKey & "["):
      return val
  return ""

proc parseDesktopFile(path: string): Option[DesktopApp] =
  let stream = newFileStream(path, fmRead)
  if stream == nil: return none(DesktopApp)
  defer: stream.close()

  var inDesktopEntrySection = false
  var entries = initTable[string, string]()

  for line in stream.lines:
    let strippedLine = line.strip()
    if strippedLine.len == 0 or strippedLine.startsWith("#"): continue

    if strippedLine.startsWith("[") and strippedLine.endsWith("]"):
      inDesktopEntrySection = (strippedLine == "[Desktop Entry]")
      continue

    if inDesktopEntrySection and "=" in strippedLine:
      let parts = strippedLine.split('=', 1)
      if parts.len == 2:
        entries[parts[0].strip()] = parts[1].strip()
  
  let name = getBestValue(entries, "Name")
  let exec = getBestValue(entries, "Exec")

  let categories = entries.getOrDefault("Categories", "")
  let icon = entries.getOrDefault("Icon", "")
  let noDisplay = entries.getOrDefault("NoDisplay", "false").toLower == "true"
  let isTerminalApp = entries.getOrDefault("Terminal", "false").toLower == "true"
  let hasIcon = icon.len > 0
  
  if noDisplay or isTerminalApp or name.len == 0 or exec.len == 0:
    return none(DesktopApp)
  
  if categories.contains("Settings") or categories.contains("System"):
    return none(DesktopApp)

  return some(DesktopApp(name: name, exec: exec, hasIcon: hasIcon))

# --- The rest of the file is completely unchanged ---
proc loadApplications() =
  echo "Searching for applications..."
  var apps = initTable[string, DesktopApp]()
  let homeDir = getHomeDir()
  let searchPaths = [homeDir / ".local/share/applications", "/usr/share/applications"]
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
          var newIsBetter: bool
          if newApp.hasIcon and not existingApp.hasIcon: newIsBetter = true
          elif not newApp.hasIcon and existingApp.hasIcon: newIsBetter = false
          else:
            let newHasFlag = newApp.exec.contains("--")
            let existingHasFlag = existingApp.exec.contains("--")
            if existingHasFlag and not newHasFlag: newIsBetter = true
            elif newHasFlag and not existingHasFlag: newIsBetter = false
            else: newIsBetter = newApp.exec.split(' ').len < existingApp.exec.split(' ').len
          if newIsBetter: apps[baseExec] = newApp
  allApps = toSeq(apps.values).sortedByIt(it.name)
  filteredApps = allApps
  echo "Found ", allApps.len, " unique applications."

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

proc parseColor(hex: string): culong =
  var r, g, b: int
  if hex.startsWith("#") and hex.len == 7:
    try:
      r = parseHexInt(hex[1..2])
      g = parseHexInt(hex[3..4])
      b = parseHexInt(hex[5..6])
    except ValueError:
      echo "Warning: Invalid hex character in color string: ", hex
      return 0
  else:
    echo "Warning: Invalid hex color format: ", hex
    return 0
  var color: XColor
  color.red = uint16(r * 257)
  color.green = uint16(g * 257)
  color.blue = uint16(b * 257)
  color.flags = cast[cchar](DoRed or DoGreen or DoBlue)
  if XAllocColor(display, XDefaultColormap(display, screen), color.addr) == 0:
    echo "Warning: Failed to allocate color: ", hex
    return 0
  return color.pixel

proc initGui() =
  display = XOpenDisplay(nil)
  if display == nil: quit "Failed to open display"
  screen = XDefaultScreen(display)
  
  config.bgColor = parseColor(config.bgColorHex)
  config.fgColor = parseColor(config.fgColorHex)
  config.highlightBgColor = parseColor(config.highlightBgColorHex)
  config.highlightFgColor = parseColor(config.highlightFgColorHex)
  config.borderColor = parseColor(config.borderColorHex)

  var finalX, finalY: cint
  if config.centerWindow:
    let screenWidth = XDisplayWidth(display, screen)
    let screenHeight = XDisplayHeight(display, screen)
    finalX = cint((screenWidth - config.winWidth) / 2)
    case config.verticalAlign
    of "top": finalY = cint(50)
    of "center": finalY = cint((screenHeight - config.winMaxHeight) / 2)
    else: finalY = cint((screenHeight - config.winMaxHeight) / 3)
  else:
    finalX = cint(config.positionX)
    finalY = cint(config.positionY)
  
  var attributes: XSetWindowAttributes
  attributes.override_redirect = true.XBool
  attributes.background_pixel = config.bgColor
  attributes.event_mask = KeyPressMask or ExposureMask or FocusChangeMask
  let valuemask: culong = CWOverrideRedirect or CWBackPixel or CWEventMask
  
  window = XCreateWindow(display, XRootWindow(display, screen), finalX, finalY,
    cuint(config.winWidth), cuint(config.winMaxHeight), 0, CopyFromParent, InputOutput, nil,
    valuemask, attributes.addr)
  
  graphicsContext = XDefaultGC(display, screen)
  discard XMapWindow(display, window)
  discard XSetInputFocus(display, window, RevertToParent, CurrentTime)
  discard XFlush(display)

proc drawText(text: string, x, y: int, isSelected: bool) =
  let (fg, bg) =
    if isSelected: (config.highlightFgColor, config.highlightBgColor)
    else: (config.fgColor, config.bgColor)
  discard XSetForeground(display, graphicsContext, fg)
  discard XSetBackground(display, graphicsContext, bg)
  discard XDrawString(display, window, graphicsContext,
                      cint(x), cint(y), cstring(text), cint(text.len))

proc redrawWindow() =
  discard XClearWindow(display, window)
  
  if config.borderWidth > 0:
    discard XSetForeground(display, graphicsContext, config.borderColor)
    for i in 0 ..< config.borderWidth:
      discard XDrawRectangle(display, window, graphicsContext,
        cint(i), cint(i),
        cuint(config.winWidth - 1 - (i*2)), cuint(config.winMaxHeight - 1 - (i*2)))

  drawText(config.prompt & inputText & config.cursor, 20, 30, isSelected = false)
  let listStartY = 50
  for i in 0 ..< config.maxVisibleItems:
    let itemIndex = viewOffset + i
    if itemIndex >= filteredApps.len: break
    let app = filteredApps[itemIndex]
    let yPos = listStartY + (i * config.lineHeight)
    let isSelected = (itemIndex == selectedIndex)
    if isSelected:
      discard XSetForeground(display, graphicsContext, config.highlightBgColor)
      discard XFillRectangle(display, window, graphicsContext,
        cint(10), cint(yPos - config.lineHeight + 5),
        cuint(config.winWidth - 20), cuint(config.lineHeight))
    drawText(app.name, 20, yPos, isSelected = isSelected)
  discard XFlush(display)

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
