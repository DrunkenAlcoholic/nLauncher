import
  os,
  osproc,
  strutils,
  streams,
  options,
  tables,
  sequtils,
  algorithm,
  # std/parsecfg has been removed
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
    bgColorHex, fgColorHex: string
    highlightBgColorHex, highlightFgColorHex: string
    bgColor, fgColor, highlightBgColor, highlightFgColor: culong

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

# --- Data Sourcing Logic (Unchanged) ---
proc getBaseExec(exec: string): string =
  let cleanExec = exec.split('%')[0].strip()
  return cleanExec.split(' ')[0].extractFilename()

proc parseDesktopFile(path: string): Option[DesktopApp] =
  var name, exec, categories: string
  var noDisplay, isTerminalApp, hasIcon, inDesktopEntrySection: bool
  let stream = newFileStream(path, fmRead)
  if stream == nil: return none(DesktopApp)
  defer: stream.close()

  for line in stream.lines:
    let strippedLine = line.strip()
    if strippedLine == "[Desktop Entry]":
      inDesktopEntrySection = true
      continue
    if not inDesktopEntrySection or strippedLine.startsWith("#") or strippedLine.len == 0:
      continue
    if "=" in strippedLine:
      let parts = strippedLine.split('=', 1)
      let key = parts[0].strip()
      let value = parts[1].strip()
      case key
      of "Name": name = value
      of "Exec": exec = value
      of "Categories": categories = value
      of "Icon":
        if value.len > 0: hasIcon = true
      of "NoDisplay":
        if value.toLower == "true": noDisplay = true
      of "Terminal":
        if value.toLower == "true": isTerminalApp = true
      else: discard
      
  if noDisplay or isTerminalApp or name.len == 0 or exec.len == 0: return none(DesktopApp)
  if categories.contains("Settings") or categories.contains("System"): return none(DesktopApp)
  
  return some(DesktopApp(name: name, exec: exec, hasIcon: hasIcon))

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
  config.winWidth = 600
  config.lineHeight = 22
  config.maxVisibleItems = 15
  let inputHeight = 40
  config.winMaxHeight = inputHeight + (config.maxVisibleItems * config.lineHeight)
  config.centerWindow = true
  config.positionX = 500
  config.positionY = 50
  config.bgColorHex = "#2E3440"
  config.fgColorHex = "#D8DEE9"
  config.highlightBgColorHex = "#88C0D0"
  config.highlightFgColorHex = "#2E3440"

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

# --- THIS PROCEDURE IS MODIFIED ---
proc initGui() =
  display = XOpenDisplay(nil)
  if display == nil: quit "Failed to open display"
  screen = XDefaultScreen(display)
  
  config.bgColor = parseColor(config.bgColorHex)
  config.fgColor = parseColor(config.fgColorHex)
  config.highlightBgColor = parseColor(config.highlightBgColorHex)
  config.highlightFgColor = parseColor(config.highlightFgColorHex)

  var finalX, finalY: cint
  if config.centerWindow:
    let screenWidth = XDisplayWidth(display, screen)
    let screenHeight = XDisplayHeight(display, screen)
    finalX = cint((screenWidth - config.winWidth) / 2)
    finalY = cint((screenHeight - config.winMaxHeight) / 3)
  else:
    finalX = cint(config.positionX)
    finalY = cint(config.positionY)
  
  var attributes: XSetWindowAttributes
  attributes.override_redirect = true.XBool
  attributes.background_pixel = config.bgColor
  # Add FocusChangeMask to the event mask
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
  drawText("> " & inputText & "_", 20, 30, isSelected = false)
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

# --- THIS PROCEDURE IS MODIFIED ---
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
      if not shouldExit: # Small polish: don't redraw if we're about to exit
        redrawWindow()
    of FocusOut: # If our window loses focus, close it.
      echo "Focus lost. Closing."
      shouldExit = true
    else: discard
  
  discard XDestroyWindow(display, window)
  discard XCloseDisplay(display)

main()
