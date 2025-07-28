# src/nim_launcher.nim

#──────────────────────────────────────────────────────────────────────────────
#  Imports
#──────────────────────────────────────────────────────────────────────────────
import
  std/[
    os, osproc, strutils, options, tables, sequtils, algorithm, parsecfg, json, times,
    editdistance, sets,
  ]
from std/uri import encodeUrl
import x11/[xlib, xutil, x, keysym]
import ./[state, parser, gui, themes, utils]

#──────────────────────────────────────────────────────────────────────────────
#  Globals
#──────────────────────────────────────────────────────────────────────────────
var currentThemeIndex = 0 ## Active index into built‑in `themeList`

#──────────────────────────────────────────────────────────────────────────────
# Proc helpers
#──────────────────────────────────────────────────────────────────────────────
proc runCommand(cmd: string) =
  ## Run `cmd` inside the chosen terminal (if any), else headless.
  let term = chooseTerminal()
  if term.len > 0:
    echo "Running in terminal: ", term, " -e ", cmd
    discard startProcess("/usr/bin/env",
                         args   = [term, "-e", "sh", "-c", cmd],
                         options = {poDaemon})
  else:
    echo "No terminal found; running headless"
    discard startProcess("/bin/sh", args = ["-c", cmd], options = {poDaemon})

proc runShell(cmd: string) =
  ## Executes `cmd` in a terminal if one is available; otherwise via plain shell.
  let term = config.terminalExe
  if term.len > 0 and exeExists(term):
    echo "Using terminal: ", term
    discard startProcess(term, args = ["-e", "sh", "-c", cmd], options = {poDaemon})
  else:
    # No terminal found—run non‑interactive command in background shell
    echo "No terminal found, running command in background shell: ", term
    discard startProcess("/bin/sh", args = ["-c", cmd], options = {poDaemon})

proc openUrl(url: string) =
  ## Launch default browser with xdg‑open.
  runShell("xdg-open '" & url & "' &")

proc scanConfigFiles*(query: string): seq[DesktopApp] =
  ## Return config files under ~/.config whose filename contains the query.
  let cfgDir = getHomeDir() / ".config"
  for path in walkDirRec(cfgDir):
    if fileExists(path) and path.extractFilename.toLower.contains(query.toLower):
      result.add DesktopApp(
        name: path.extractFilename, exec: "xdg-open '" & path & "'", hasIcon: false
      )

#──────────────────────────────────────────────────────────────────────────────
#  Theme helpers
#──────────────────────────────────────────────────────────────────────────────
proc applyTheme(config: var state.Config, name: string) =
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
  ## Convert hex → X pixel (needs X connection).
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
  currentThemeIndex = (currentThemeIndex + 1) mod themeList.len
  let th = themeList[currentThemeIndex]
  applyTheme(config, th.name)
  gui.notifyThemeChanged(th.name)
  updateParsedColors(config)
  gui.updateGuiColors()
  gui.redrawWindow()

#──────────────────────────────────────────────────────────────────────────────
#  Application discovery with smart cache
#──────────────────────────────────────────────────────────────────────────────
proc loadApplications() =
  let tStart = epochTime()
  let home = getHomeDir()
  let usrDir = "/usr/share/applications"
  let locDir = home / ".local/share/applications"
  let cacheDir = home / ".cache" / "nim_launcher"
  let cacheFile = cacheDir / "apps.json"

  # 1. mtime stamps
  let usrM: int64 =
    if dirExists(usrDir):
      getLastModificationTime(usrDir).toUnix
    else:
      0'i64
  let locM: int64 =
    if dirExists(locDir):
      getLastModificationTime(locDir).toUnix
    else:
      0'i64

  # 2. cache hit?
  if fileExists(cacheFile):
    try:
      let c = to(parseJson(readFile(cacheFile)), CacheData)
      if c.usrMtime == usrM and c.localMtime == locM:
        allApps = c.apps
        filteredApps = allApps
        echo "Cache hit: ", allApps.len, " apps (", epochTime() - tStart, "s)"
        return
    except JsonParsingError, ValueError, IOError:
      echo "Cache missing/corrupt — rescan."

  # 3. scan *.desktop
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

  # 4. write cache
  try:
    createDir(cacheDir)
    writeFile(
      cacheFile, pretty(%CacheData(usrMtime: usrM, localMtime: locM, apps: allApps))
    )
  except OSError:
    echo "Warning: cannot save cache."

  echo "Scan done in ", epochTime() - tStart, "s"

#──────────────────────────────────────────────────────────────────────────────
#  initLauncherConfig  – defaults → INI override → derived values
#──────────────────────────────────────────────────────────────────────────────
proc initLauncherConfig() =
  ## Populate `config` with defaults, then override them from
  ## ~/.config/nim_launcher/config.ini  (created automatically).

  # ── 1. Built‑in defaults ───────────────────────────────────────────
  config.winWidth            = 600
  config.lineHeight          = 22
  config.maxVisibleItems     = 15
  config.centerWindow        = true
  config.positionX           = 500
  config.positionY           = 50
  config.verticalAlign       = "one-third"

  config.bgColorHex          = "#2E3440"
  config.fgColorHex          = "#D8DEE9"
  config.highlightBgColorHex = "#88C0D0"
  config.highlightFgColorHex = "#2E3440"
  config.borderColorHex      = "#4C566A"
  config.borderWidth         = 2

  config.prompt              = "> "
  config.cursor              = "_"
  config.fontName            = "Noto Sans:size=11"
  config.themeName           = ""
  config.terminalExe         = "gnome-terminal"

  # ── 2. Ensure INI file exists ──────────────────────────────────────
  let cfgPath = getHomeDir() / ".config" / "nim_launcher" / "config.ini"
  if not fileExists(cfgPath):
    const iniTemplate = """
[window]
width              = 600
max_visible_items  = 15
center             = true
position_x         = 500
position_y         = 50
vertical_align     = "one-third"

[font]
fontname = Noto Sans:size=11

[input]
prompt   = "> "
cursor   = "_"

[terminal]
program  = "gnome-terminal"

[border]
width    = 2

[colors]
background           = "#2E3440"
foreground           = "#D8DEE9"
highlight_background = "#88C0D0"
highlight_foreground = "#2E3440"
border_color         = "#4C566A"

[theme]
#name = "Nord"
"""
    createDir(cfgPath.parentDir)
    writeFile(cfgPath, iniTemplate)
    echo "Created default config at ", cfgPath

  # ── 3. Parse INI ───────────────────────────────────────────────────
  let ini = loadConfig(cfgPath)

  for sec, table in ini:
    for key, val in table:
      if sec == "window":
        case key
        of "width":              config.winWidth        = val.parseInt
        of "max_visible_items":  config.maxVisibleItems = val.parseInt
        of "center":             config.centerWindow    = (val.toLower == "true")
        of "position_x":         config.positionX       = val.parseInt
        of "position_y":         config.positionY       = val.parseInt
        of "vertical_align":     config.verticalAlign   = val
        else: discard

      elif sec == "colors":
        case key
        of "background":           config.bgColorHex          = val
        of "foreground":           config.fgColorHex          = val
        of "highlight_background": config.highlightBgColorHex = val
        of "highlight_foreground": config.highlightFgColorHex = val
        of "border_color":         config.borderColorHex      = val
        else: discard

      elif sec == "border":
        if key == "width":
          config.borderWidth = val.parseInt

      elif sec == "input":
        case key
        of "prompt": config.prompt = val
        of "cursor": config.cursor = val
        else: discard

      elif sec == "font":
        if key == "fontname":
          config.fontName = val

      elif sec == "terminal":
        if key == "program":
          config.terminalExe = val.strip(chars = {'"', '\''})


      elif sec == "theme":
        if key == "name":
          config.themeName = val

  # ── 4. Apply named theme if provided ───────────────────────────────
  if config.themeName.len > 0:
    applyTheme(config, config.themeName)

  # ── 5. Derived geometry ────────────────────────────────────────────
  config.winMaxHeight = 40 + config.maxVisibleItems * config.lineHeight
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
  ## Rebuilds `filteredApps` according to the active input mode and query.

  # ── 1. Detect input mode from leading prefix ───────────────────────
  if inputText.startsWith("/c "):
    inputMode = imConfigSearch          # ~/.config file search
  elif inputText.startsWith("/y "):
    inputMode = imYouTube               # YouTube search
  elif inputText.startsWith("/g "):
    inputMode = imGoogle                # Google search
  elif inputText.startsWith("/") and inputText.len > 1:
    inputMode = imRunCommand            # direct shell command
  else:
    inputMode = imNormal                # normal application search

    # ── 2. Populate `filteredApps` for each mode ───────────────────────
  case inputMode
  of imNormal:
    if inputText.len == 0:
      ## No query → show recent apps first, but avoid duplicates
      var rec: seq[DesktopApp]
      var recentSet: HashSet[string]          # names already added
      for n in recentApps:
        var idx = -1
        for i, a in allApps:
          if a.name == n:
            idx = i
            break
        if idx >= 0:
          rec.add allApps[idx]
          recentSet.incl n

      # Append the rest of the apps whose names aren’t in recentSet
      filteredApps = rec & allApps.filterIt(not recentSet.contains(it.name))
    else:
      filteredApps = allApps.filterIt(betterFuzzyMatch(inputText, it.name))

  of imRunCommand:
    filteredApps = @[
      DesktopApp(
        name: "Run: " & inputText[1 .. ^1].strip(),
        exec: inputText[1 .. ^1].strip(),
        hasIcon: false,
      )
    ]

  of imConfigSearch:
    let query = inputText[3 .. ^1].strip()
    filteredApps = scanConfigFiles(query)

  of imYouTube:
    let query = inputText[3 .. ^1].strip()
    let url   = "https://www.youtube.com/results?search_query=" & encodeUrl(query)
    filteredApps = @[DesktopApp(name: "Search YouTube: " & query,
                                exec: url,
                                hasIcon: false)]

  of imGoogle:
    let query = inputText[3 .. ^1].strip()
    let url   = "https://www.google.com/search?q=" & encodeUrl(query)
    filteredApps = @[DesktopApp(name: "Search Google: " & query,
                                exec: url,
                                hasIcon: false)]


  # ── 3. Reset selection & scroll ────────────────────────────────────
  selectedIndex = 0
  viewOffset    = 0


#──────────────────────────────────────────────────────────────────────────────
#  Launch & key handling
#──────────────────────────────────────────────────────────────────────────────
proc launchSelectedApp() =
  ## Execute whatever is currently selected / typed.

  # 1. Explicit “/command …” ------------------------------------------------
  if inputMode == imRunCommand:
    let cmd = inputText[1 .. ^1].strip()       # drop leading '/'
    if cmd.len > 0:
      echo "DEBUG: executing -> ", cmd
      runCommand(cmd)                          # wrap in terminal / headless
    shouldExit = true
    return

  # 2. Guard against empty list selections ---------------------------------
  if selectedIndex notin 0 ..< filteredApps.len: return
  let app = filteredApps[selectedIndex]

  # 3. Mode‑specific launches ----------------------------------------------
  case inputMode
  of imYouTube, imGoogle:
    openUrl(app.exec)                          # browser URL

  of imConfigSearch:
    discard startProcess("/bin/sh",
                         args = ["-c", app.exec],
                         options = {poDaemon}) # xdg-open file (no terminal)

  else: # imNormal ----------------------------------------------------------
    let cleanExec = app.exec.split('%')[0].strip()
    discard startProcess("/bin/sh",
                         args = ["-c", cleanExec],
                         options = {poDaemon}) # launch app directly

  # 4. Update recent‑apps list (imNormal only) ------------------------------
  if inputMode == imNormal:
    let n = app.name
    let idx = recentApps.find(n)       # -1 if not present
    if idx >= 0:                       # guard against RangeDefect
      recentApps.delete(idx)

    recentApps.insert(n, 0)            # push to front
    if recentApps.len > maxRecent:
      recentApps.setLen(maxRecent)
    saveRecent()

  shouldExit = true


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
#  Main loop
#──────────────────────────────────────────────────────────────────────────────
proc main() =
  benchMode = "--bench" in commandLineParams()
  initLauncherConfig()
  loadApplications()
  loadRecent() 
  updateFilteredApps()
  initGui()
  if benchMode:          # unchanged logic, now uses global flag
    redrawWindow()
    quit 0
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
