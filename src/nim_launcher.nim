# src/nim_launcher.nim

#──────────────────────────────────────────────────────────────────────────────
#  Imports
#──────────────────────────────────────────────────────────────────────────────
import
  std/[
    os, osproc, strutils, options, tables, sequtils, algorithm, parsecfg, json, times,
    editdistance,
  ]
import x11/[xlib, xutil, x, keysym]
import ./[state, parser, gui, themes]

#──────────────────────────────────────────────────────────────────────────────
#  Globals
#──────────────────────────────────────────────────────────────────────────────
var currentThemeIndex = 0 ## Active index into built‑in `themeList`

#──────────────────────────────────────────────────────────────────────────────
#  Theme helpers
#──────────────────────────────────────────────────────────────────────────────
proc applyTheme(config: var state.Config, name: string) =
  ## Copy theme colours into `config` by `name` (case‑insensitive).
  for i, th in themeList:
    if th.name.toLower == name.toLower:
      config.bgColorHex = th.bgColorHex
      config.fgColorHex = th.fgColorHex
      config.highlightBgColorHex = th.highlightBgColorHex
      config.highlightFgColorHex = th.highlightFgColorHex
      config.borderColorHex = th.borderColorHex
      currentThemeIndex = i
      return

proc updateParsedColors(config: var state.Config) =
  ## Translate all hex strings in `config` to X11 pixel values (requires display).
  if config.bgColorHex.len == 7:
    config.bgColor = parseColor(config.bgColorHex)
  if config.fgColorHex.len == 7:
    config.fgColor = parseColor(config.fgColorHex)
  if config.highlightBgColorHex.len == 7:
    config.highlightBgColor = parseColor(config.highlightBgColorHex)
  if config.highlightFgColorHex.len == 7:
    config.highlightFgColor = parseColor(config.highlightFgColorHex)
  if config.borderColorHex.len == 7:
    config.borderColor = parseColor(config.borderColorHex)

proc cycleTheme(config: var state.Config) =
  ## Rotate to next theme, refresh GUI, and flash overlay text.
  currentThemeIndex = (currentThemeIndex + 1) mod themeList.len
  let th = themeList[currentThemeIndex]
  applyTheme(config, th.name)

  gui.notifyThemeChanged(th.name) # bottom‑right overlay
  updateParsedColors(config)
  gui.updateGuiColors()
  gui.redrawWindow()

#──────────────────────────────────────────────────────────────────────────────
#  Application discovery with smart cache
#──────────────────────────────────────────────────────────────────────────────
proc loadApplications() =
  ## Build `allApps` & `filteredApps` either from cache or by scanning `.desktop`.
  let tStart = epochTime()
  let home = getHomeDir()
  let usrDir = "/usr/share/applications"
  let locDir = home / ".local/share/applications"
  let cacheDir = home / ".cache" / "nim_launcher"
  let cacheFile = cacheDir / "apps.json"

  # Directory mtimes for invalidation
  var usrM, locM: float
  if dirExists(usrDir):
    usrM = getLastModificationTime(usrDir).toUnixFloat()
  if dirExists(locDir):
    locM = getLastModificationTime(locDir).toUnixFloat()

  # Attempt cache read
  if fileExists(cacheFile):
    try:
      let c = to(parseJson(readFile(cacheFile)), CacheData)
      if c.usrMtime == usrM and c.localMtime == locM:
        allApps = c.apps
        filteredApps = allApps
        echo "Cache hit: ", allApps.len, " apps (", epochTime() - tStart, "s)"
        return
    except JsonParsingError, ValueError:
      echo "Cache corrupt — rescan." # fall through

  # Full scan
  echo "Scanning .desktop files …"
  var apps = initTable[string, DesktopApp]()
  for dir in [locDir, usrDir]:
    if not dirExists(dir):
      continue
    for p in walkFiles(dir / "*.desktop"):
      let opt = parseDesktopFile(p)
      if opt.isSome:
        let app = opt.get()
        let key = getBaseExec(app.exec)
        if not apps.hasKey(key) or (app.hasIcon and not apps[key].hasIcon):
          apps[key] = app

  allApps = toSeq(apps.values).sortedByIt(it.name)
  filteredApps = allApps
  echo "Indexed ", allApps.len, " apps."

  # Write cache
  try:
    createDir(cacheDir)
    writeFile(
      cacheFile, pretty(%CacheData(usrMtime: usrM, localMtime: locM, apps: allApps))
    )
  except OSError:
    echo "Warning: cannot save cache."

  echo "Scan done in ", epochTime() - tStart, "s"

#──────────────────────────────────────────────────────────────────────────────
#  Config loader (defaults + INI)
#──────────────────────────────────────────────────────────────────────────────
proc initLauncherConfig() =
  ## Populate global `config` with defaults, then override via
  ## ~/.config/nim_launcher/config.ini (auto‑generated if absent).

  # ── 1. Hard‑coded defaults ─────────────────────────────────────────
  config.winWidth = 600
  config.lineHeight = 22
  config.maxVisibleItems = 15
  config.centerWindow = true
  config.positionX = 500
  config.positionY = 50
  config.verticalAlign = "one-third" # or "top", "center"

  config.bgColorHex = "#2E3440"
  config.fgColorHex = "#D8DEE9"
  config.highlightBgColorHex = "#88C0D0"
  config.highlightFgColorHex = "#2E3440"
  config.borderColorHex = "#4C566A"
  config.borderWidth = 2

  config.prompt = "> "
  config.cursor = "_"
  config.fontName = "Noto Sans:size=11"
  config.themeName = ""

  # ── 2. Ensure INI exists ───────────────────────────────────────────
  let cfgPath = getHomeDir() / ".config" / "nim_launcher" / "config.ini"
  if not fileExists(cfgPath):
    const tmpl =
      """[window]
width = 600
max_visible_items = 15
center = true
position_x = 500
position_y = 50
vertical_align = "one-third"

[font]
fontname = Noto Sans:size=11

[input]
prompt = "> "
cursor = "_"

[border]
width = 2

[colors]
background = "#2E3440"
foreground = "#D8DEE9"
highlight_background = "#88C0D0"
highlight_foreground = "#2E3440"
border_color = "#4C566A"

[theme]
# Leaving this empty will use the colour scheme in the [colors] section. 
# or choose one of the inbuilt themes below to override by un-commenting.
#name = "Ayu Dark"
#name = "Ayu Light"
#name = "Catppuccin Frappe"
#name = "Catppuccin Latte"
#name = "Catppuccin Macchiato"
#name = "Catppuccin Mocha"
#name = "Cobalt"
#name = "Dracula"
#name = "GitHub Dark"
#name = "GitHub Light"
#name = "Gruvbox Dark"
#name = "Gruvbox Light"
#name = "Material Dark"
#name = "Material Light"
#name = "Monokai"
#name = "Monokai Pro"
#name = "Nord"
#name = "One Dark"
#name = "One Light"
#name = "Palenight"
#name = "Solarized Dark"
#name = "Solarized Light"
#name = "Synthwave 84"
#name = "Tokyo Night"
#name = "Tokyo Night Light"

"""

    try:
      createDir(cfgPath.parentDir)
      writeFile(cfgPath, tmpl)
      echo "Created default config at ", cfgPath
    except OSError:
      echo "Warning: could not write default config."

  # ── 3. Parse INI ───────────────────────────────────────────────────
  if fileExists(cfgPath):
    let ini = loadConfig(cfgPath)
    proc gs(sec, key, d: string): string =
      ini.getSectionValue(sec, key, d)

    proc gi(sec, key: string, d: int): int =
      try:
        parseInt(gs(sec, key, $d))
      except ValueError:
        d

    config.winWidth = gi("window", "width", config.winWidth)
    config.maxVisibleItems = gi("window", "max_visible_items", config.maxVisibleItems)
    config.centerWindow =
      (gs("window", "center", $config.centerWindow)).toLower == "true"
    config.positionX = gi("window", "position_x", config.positionX)
    config.positionY = gi("window", "position_y", config.positionY)
    config.verticalAlign = gs("window", "vertical_align", config.verticalAlign)

    config.bgColorHex = gs("colors", "background", config.bgColorHex)
    config.fgColorHex = gs("colors", "foreground", config.fgColorHex)
    config.highlightBgColorHex =
      gs("colors", "highlight_background", config.highlightBgColorHex)
    config.highlightFgColorHex =
      gs("colors", "highlight_foreground", config.highlightFgColorHex)
    config.borderColorHex = gs("colors", "border_color", config.borderColorHex)
    config.borderWidth = gi("border", "width", config.borderWidth)

    config.prompt = gs("input", "prompt", config.prompt)
    config.cursor = gs("input", "cursor", config.cursor)
    config.fontName = gs("font", "fontname", config.fontName)
    config.themeName = gs("theme", "name", config.themeName)

  # ── 4. Apply named theme if requested ─────────────────────────────
  if config.themeName.len > 0:
    for th in themeList:
      if th.name.toLower == config.themeName.toLower:
        applyTheme(config, th.name)
        break

  # ── 5. Compute window height ──────────────────────────────────────
  let inputH = 40
  config.winMaxHeight = inputH + config.maxVisibleItems * config.lineHeight

  echo "Using font: ", config.fontName

#──────────────────────────────────────────────────────────────────────────────
#  Fuzzy match / filtering
#──────────────────────────────────────────────────────────────────────────────
proc betterFuzzyMatch(q, t: string): bool =
  ## Substring → Levenshtein ≤2 → subsequence fallback.
  let lowerQ = q.toLowerAscii
  let lowerT = t.toLowerAscii
  if lowerQ.len == 0:
    return true
  if lowerT.contains(lowerQ):
    return true
  if editDistanceAscii(lowerQ, lowerT) <= 2:
    return true
  var qi = 0
  for ch in lowerT:
    if qi < lowerQ.len and lowerQ[qi] == ch:
      inc qi
    if qi == lowerQ.len:
      return true
  false

proc updateFilteredApps() =
  filteredApps = allApps.filter(
    proc(a: DesktopApp): bool =
      betterFuzzyMatch(inputText, a.name)
  )
  selectedIndex = 0
  viewOffset = 0

#──────────────────────────────────────────────────────────────────────────────
#  Launch & key handling
#──────────────────────────────────────────────────────────────────────────────
proc launchSelectedApp() =
  ## Launch the currently selected application via /bin/sh ‑c.
  if selectedIndex notin 0 ..< filteredApps.len:
    return
  let app = filteredApps[selectedIndex]
  let cmd = app.exec.split('%')[0].strip()
  try:
    echo "Launching: ", cmd
    discard startProcess("/bin/sh", args = ["-c", cmd], options = {poDaemon})
    shouldExit = true
  except OSError:
    echo "Failed to launch: ", cmd

proc handleKeyPress(event: var XEvent) =
  ## Map X11 keysyms → launcher actions.
  var buf: array[40, char]
  var ks: KeySym
  discard XLookupString(
    event.xkey.addr, cast[cstring](buf[0].addr), buf.len.cint, ks.addr, nil
  )
  case ks
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
      dec selectedIndex
      if selectedIndex < viewOffset:
        viewOffset = selectedIndex
  of XK_Down:
    if selectedIndex < filteredApps.len - 1:
      inc selectedIndex
      if selectedIndex >= viewOffset + config.maxVisibleItems:
        viewOffset = selectedIndex - config.maxVisibleItems + 1
  of XK_F5:
    cycleTheme(config)
  else:
    if buf[0] != '\0' and buf[0] >= ' ':
      inputText.add(buf[0])
      updateFilteredApps()

#──────────────────────────────────────────────────────────────────────────────
#  Main event loop
#──────────────────────────────────────────────────────────────────────────────
proc main() =
  initLauncherConfig()
  loadApplications()
  initGui()
  updateParsedColors(config)

  while not shouldExit:
    var ev: XEvent
    discard XNextEvent(display, ev.addr)
    case ev.theType
    of Expose:
      gui.redrawWindow()
    of KeyPress:
      handleKeyPress(ev)
      if not shouldExit:
        gui.redrawWindow()
    of FocusOut:
      echo "Focus lost — exiting"
      shouldExit = true
    else:
      discard

  discard XDestroyWindow(display, window)
  discard XCloseDisplay(display)

when isMainModule:
  main()
