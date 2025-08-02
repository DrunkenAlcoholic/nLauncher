# src/nLauncher.nim
## nLauncher.nim — main program with Action abstraction and fixes
## MIT; see LICENSE for details.
## Requires Nim ≥ 2.0 with x11 & xft packages.
## Startup in --bench mode still completes in ~1–2 ms on a modern system.

# ── Imports ─────────────────────────────────────────────────────────────
import std/[os, osproc, strutils, options, tables, sequtils,
             json, times, editdistance, uri, sets, algorithm]
import parsetoml as toml
import x11/[xlib, x, xutil, keysym]
import ./[state, parser, gui, utils]

# ── Module‑local globals ────────────────────────────────────────────────
var
  currentThemeIndex = 0           ## Active index into `themeList`
  actions*: seq[Action]           ## Current selectable actions

# ── Utility procs ──────────────────────────────────────────────────────
proc runCommand(cmd: string) =
  ## Execute *cmd* in the chosen terminal, else headless.
  let term = chooseTerminal()
  # Debug: show which terminal and command are being used
  #echo "DEBUG ▶ runCommand: term='", term, "' cmd='", cmd, "'"

  if term.len > 0:
    #echo "DEBUG ▶ launching via terminal: ", term, " -e sh -c ", cmd
    discard startProcess("/usr/bin/env",
      args = [term, "-e", "sh", "-c", cmd], options = {poDaemon})
  else:
    #echo "DEBUG ▶ launching via shell: /bin/sh -c ", cmd
    discard startProcess("/bin/sh",
      args = ["-c", cmd], options = {poDaemon})

proc openUrl(url: string) =
  ## Open *url* via `xdg-open` in the background using the shell.
  discard startProcess("/bin/sh",
    args = @["-c", "xdg-open \"" & url & "\" &"], options = {poDaemon})

proc scanConfigFiles*(query: string): seq[DesktopApp] =
  ## Return config files matching *query*.
  let base = getHomeDir() / ".config"
  for path in walkDirRec(base):
    if fileExists(path) and path.extractFilename.toLower.contains(query.toLower):
      result.add DesktopApp(
        name:     path.extractFilename,
        exec:     "xdg-open " & shellQuote(path),
        hasIcon:  false
      )

# ── Theme helpers ───────────────────────────────────────────────────────
proc applyTheme*(cfg: var Config; name: string) =
  ## Copy colours from named theme into *cfg* and record the name.
  for i, th in themeList:
    if th.name.toLower == name.toLower:
      cfg.bgColorHex          = th.bgColorHex
      cfg.fgColorHex          = th.fgColorHex
      cfg.highlightBgColorHex = th.highlightBgColorHex
      cfg.highlightFgColorHex = th.highlightFgColorHex
      cfg.borderColorHex      = th.borderColorHex
      cfg.themeName           = th.name            # ← record the chosen theme
      currentThemeIndex       = i
      return

proc updateParsedColors(cfg: var Config) =
  ## Resolve hex → pixel colours.
  cfg.bgColor          = parseColor(cfg.bgColorHex)
  cfg.fgColor          = parseColor(cfg.fgColorHex)
  cfg.highlightBgColor = parseColor(cfg.highlightBgColorHex)
  cfg.highlightFgColor = parseColor(cfg.highlightFgColorHex)
  cfg.borderColor      = parseColor(cfg.borderColorHex)

proc saveLastTheme(cfgPath: string) =
  var lines = readFile(cfgPath).splitLines()
  var inTheme = false
  for i in 0..<lines.len:
    let l = lines[i].strip()
    if l == "[theme]":
      inTheme = true; continue
    if inTheme:
      if l.startsWith("[") and l.endsWith("]"):
        break
      if l.startsWith("last_chosen"):
        lines[i] = "last_chosen = \"" & config.themeName & "\""
        break
  writeFile(cfgPath, join(lines, "\n"))


proc cycleTheme*(cfg: var Config) =
  currentThemeIndex = (currentThemeIndex + 1) mod themeList.len
  let th = themeList[currentThemeIndex]
  applyTheme(cfg, th.name)
  gui.notifyThemeChanged(th.name)
  updateParsedColors(cfg)
  gui.updateGuiColors()
  gui.redrawWindow()

  # now config.themeName is set correctly:
  saveLastTheme(getHomeDir() / ".config" / "nlauncher" / "nlauncher.toml")

# ── Applications discovery ──────────────────────────────────────────────
proc loadApplications() =
  let usrDir   = "/usr/share/applications"
  let locDir   = getHomeDir() / ".local/share/applications"
  let cacheDir  = getHomeDir() / ".cache" / "nlauncher"
  let cacheFile = cacheDir / "apps.json"

  let usrM = if dirExists(usrDir): getLastModificationTime(usrDir).toUnix else: 0'i64
  let locM = if dirExists(locDir): getLastModificationTime(locDir).toUnix else: 0'i64

  # Cache hit
  if fileExists(cacheFile):
    try:
      let c = to(parseJson(readFile(cacheFile)), CacheData)
      if c.usrMtime == usrM and c.localMtime == locM:
        timeIt "Cache hit:" :
          allApps      = c.apps
          filteredApps = allApps
        return
    except:
      echo "Cache miss — rescanning …"

  # Full scan
  timeIt "Full scan:" :
    var dedup = initTable[string, DesktopApp]()
    for dir in @[locDir, usrDir]:
      if not dirExists(dir): continue
      for path in walkFiles(dir / "*.desktop"):
        let opt = parseDesktopFile(path)
        if opt.isSome:
          let app = opt.get()
          let key = getBaseExec(app.exec)
          if not dedup.hasKey(key) or (app.hasIcon and not dedup[key].hasIcon):
            dedup[key] = app

    allApps = dedup.values.toSeq
    allApps.sort(proc(a, b: DesktopApp): int = cmpIgnoreCase(a.name, b.name))
    filteredApps = allApps
    try:
      createDir(cacheDir)
      writeFile(cacheFile,
        pretty(%CacheData(usrMtime: usrM, localMtime: locM, apps: allApps)))
    except:
      echo "Warning: cache not saved."


# ── Load & apply config from TOML ───────────────────────────────────────────
proc initLauncherConfig() =
  ## Initialize defaults, then override via TOML.
  config = Config()  # zero‑init

  # In‑code defaults (fallbacks)
  config.winWidth        = 500
  config.lineHeight      = 22
  config.maxVisibleItems = 10
  config.centerWindow    = true
  config.positionX       = 20
  config.positionY       = 50
  config.verticalAlign   = "one-third"
  config.fontName        = "Noto Sans:size=12"
  config.prompt          = "> "
  config.cursor          = "_"
  config.terminalExe     = "gnome-terminal"
  config.borderWidth     = 2

  # Ensure TOML config exists
  let cfgDir  = getHomeDir() / ".config" / "nlauncher"
  let cfgPath = cfgDir / "nlauncher.toml"
  if not fileExists(cfgPath):
    createDir(cfgDir)
    writeFile(cfgPath, defaultToml)
    echo "Created default config at ", cfgPath

  # Parse the TOML
  let tbl = toml.parseFile(cfgPath)

  # ── window section ─────────────────────────────────────────────────────
  let w = tbl["window"]
  config.winWidth        = w["width"].getInt(config.winWidth)
  config.maxVisibleItems = w["max_visible_items"].getInt(config.maxVisibleItems)
  config.centerWindow    = w["center"].getBool(config.centerWindow)
  config.positionX       = w["position_x"].getInt(config.positionX)
  config.positionY       = w["position_y"].getInt(config.positionY)
  config.verticalAlign   = w["vertical_align"].getStr(config.verticalAlign)

  # ── font section ───────────────────────────────────────────────────────
  let f = tbl["font"]
  config.fontName = f["fontname"].getStr(config.fontName)

  # ── input section ──────────────────────────────────────────────────────
  let inp = tbl["input"]
  config.prompt = inp["prompt"].getStr(config.prompt)
  config.cursor = inp["cursor"].getStr(config.cursor)

  # ── terminal section ───────────────────────────────────────────────────
  let term = tbl["terminal"]
  config.terminalExe = term["program"].getStr(config.terminalExe)

  # ── border section ─────────────────────────────────────────────────────
  let b = tbl["border"]
  config.borderWidth = b["width"].getInt(config.borderWidth)

  # ── themes array ───────────────────────────────────────────────────────
  themeList = @[]
  for thVal in tbl["themes"].getElems():
    let th = thVal.getTable()
    themeList.add Theme(
      name:                th["name"].getStr(""),
      bgColorHex:          th["bgColorHex"].getStr(""),
      fgColorHex:          th["fgColorHex"].getStr(""),
      highlightBgColorHex: th["highlightBgColorHex"].getStr(""),
      highlightFgColorHex: th["highlightFgColorHex"].getStr(""),
      borderColorHex:      th["borderColorHex"].getStr("")
    )

  # ── last_chosen ────────────────────────────────────────────────────────
  let lastName = tbl["theme"]["last_chosen"].getStr("")
  var pickedIndex = -1
  
  # Try to find the saved theme in the list
  if lastName.len > 0:
    for i, th in themeList:
      if th.name == lastName:
        pickedIndex = i
        break
  
  # Fallback to the first theme if not found
  if pickedIndex < 0:
    if themeList.len > 0:
      pickedIndex = 0
    else:
      quit("nLauncher error: no themes defined in nlauncher.toml")
  
  # Apply the chosen theme
  let chosen = themeList[pickedIndex].name
  config.themeName = chosen
  applyTheme(config, chosen)
  
  # If we fell back, persist the new choice
  if chosen != lastName:
    saveLastTheme(cfgPath)
  
  # Recompute derived state
  config.winMaxHeight = 40 + config.maxVisibleItems * config.lineHeight

# ── Fuzzy match helper ─────────────────────────────────────────────────
proc betterFuzzyMatch(q, t: string): bool =
  ## Substring → editDistance ≤2 → subsequence fallback
  let lq = q.toLowerAscii
  let lt = t.toLowerAscii
  if lq.len == 0 or lt.contains(lq): return true
  if editDistanceAscii(lq, lt) <= 2: return true
  var qi = 0
  for ch in lt:
    if qi < lq.len and lq[qi] == ch: inc qi
    if qi == lq.len: return true
  false

# ── Build actions & mirror to filteredApps ─────────────────────────────
proc buildActions() =
  actions.setLen(0)
  if inputText.startsWith("/c "):
    for a in scanConfigFiles(inputText[3..^1].strip()):
      actions.add Action(kind: akConfig, label: a.name, exec: a.exec)
  elif inputText.startsWith("/y "):
    let q = inputText[3..^1].strip()
    actions.add Action(kind: akYouTube, label: "Search YouTube: " & q,
                       exec:  "https://www.youtube.com/results?search_query=" & encodeUrl(q))
  elif inputText.startsWith("/g "):
    let q = inputText[3..^1].strip()
    actions.add Action(kind: akGoogle, label: "Search Google: " & q,
                       exec:  "https://www.google.com/search?q=" & encodeUrl(q))
  elif inputText.startsWith("/w "):
    let q = inputText[3..^1].strip()
    actions.add Action(kind: akWiki, label: "Search Wiki: " & q,
                       exec:  "https://en.wikipedia.org/wiki/Special:Search?search=" & encodeUrl(q))
  elif inputText.startsWith("/") and inputText.len > 1:
    let cmd = inputText[1..^1].strip()
    #echo "DEBUG ▶ slash-trigger detected, cmd = '", cmd, "'"   # ← debug print
    actions.add Action(kind: akRun, label: "Run: " & cmd, exec: cmd)
  else:
    if inputText.len == 0:
      var seen = initHashSet[string]()
      for name in recentApps:
        for app in allApps:
          if app.name == name:
            actions.add Action(kind: akApp, label: app.name,
                               exec: app.exec, appData: app)
            seen.incl name
            break
      for app in allApps:
        if not seen.contains(app.name):
          actions.add Action(kind: akApp, label: app.name,
                             exec: app.exec, appData: app)
    else:
      for app in allApps:
        if betterFuzzyMatch(inputText, app.name):
          actions.add Action(kind: akApp, label: app.name,
                             exec: app.exec, appData: app)

  filteredApps = @[]
  for act in actions:
    filteredApps.add DesktopApp(
      name:    act.label,
      exec:    act.exec,
      hasIcon: (act.kind == akApp and act.appData.hasIcon)
    )
  selectedIndex = 0
  viewOffset    = 0

# ── Perform selected action ─────────────────────────────────────────────
proc performAction(a: Action) =
  case a.kind
  of akRun:
    #echo "DEBUG ▶ about to run: ", a.exec
    runCommand(a.exec)
  of akYouTube, akGoogle, akWiki:
    openUrl(a.exec)
  of akConfig, akApp:
    discard startProcess("/bin/sh", args = ["-c", a.exec.split('%')[0].strip()], options={poDaemon})
    #if a.kind == akConfig:
    #  discard startProcess("/bin/sh", args = ["-c", a.exec], options={poDaemon})
    #else:
    #  discard startProcess("/bin/sh", args = ["-c", a.exec.split('%')[0].strip()], options={poDaemon})
    if a.kind == akApp:
      if a.label in recentApps:
        recentApps.delete(recentApps.find(a.label))
      recentApps.insert(a.label, 0)
      if recentApps.len > maxRecent: recentApps.setLen(maxRecent)
      saveRecent()
  shouldExit = true

# ── Key handling ────────────────────────────────────────────────────────
proc handleKeyPress(ev: var XEvent) =
  var buf: array[40, char]
  var ks: KeySym
  discard XLookupString(ev.xkey.addr, cast[cstring](buf[0].addr), buf.len.cint, ks.addr, nil)
  case ks
  of XK_Escape: shouldExit = true
  of XK_Return:
    if selectedIndex in 0..<actions.len: performAction(actions[selectedIndex])
  of XK_BackSpace:
    if inputText.len > 0:
      inputText.setLen(inputText.len - 1)
      buildActions()
  of XK_Up:
    if selectedIndex > 0:
      dec selectedIndex
      if selectedIndex < viewOffset: viewOffset = selectedIndex
  of XK_Down:
    if selectedIndex < filteredApps.len - 1:
      inc selectedIndex
      if selectedIndex >= viewOffset + config.maxVisibleItems:
        viewOffset = selectedIndex - config.maxVisibleItems + 1
  of XK_F5: cycleTheme(config)
  else:
    if buf[0] != '\0' and buf[0] >= ' ':
      inputText.add(buf[0])
      buildActions()

# ── Main loop ───────────────────────────────────────────────────────────
proc main() =
  benchMode = "--bench" in commandLineParams()

  timeIt "Init Config:"       : initLauncherConfig()
  timeIt "Load Applications:" : loadApplications()
  timeIt "Load Recent Apps:"  :  loadRecent()
  timeIt "Build Actions:"     : buildActions()
  
  initGui()
  
  timeIt "updateParsedColors:"      :  updateParsedColors(config)
  timeIt "updateGuiColors:"         : gui.updateGuiColors()
  timeIt "Benchmark(Redraw Frame):" : gui.redrawWindow()

  if benchMode:
    quit 0


  while not shouldExit:
    var ev: XEvent
    discard XNextEvent(display, ev.addr)
    case ev.theType

    of MapNotify:
      # window was just mapped; next FocusOut is spurious → swallow it
      if ev.xmap.window == window:
        seenMapNotify = true

    of Expose:
      gui.redrawWindow()

    of KeyPress:
      handleKeyPress(ev)
      if not shouldExit:
        gui.redrawWindow()

    of ButtonPress:
      # any click (inside or outside) closes launcher
      shouldExit = true

    of FocusOut:
      if seenMapNotify:
        # discard this one, reset flag
        seenMapNotify = false
      else:
        # real blur → exit
        shouldExit = true

    else:
      discard

  discard XDestroyWindow(display, window)
  discard XCloseDisplay(display)

when isMainModule:
  main()
