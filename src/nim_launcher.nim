## nim_launcher.nim — main program with Action abstraction and fixes
## GNU GPL v3 (or later). Requires Nim ≥ 2.0, x11 & xft Nimble packages.
## Startup in --bench mode still completes in ~1–2 ms on a modern system.

# ── Imports ─────────────────────────────────────────────────────────────
import std/[os, osproc, strutils, options, tables, sequtils,
             json, times, editdistance, uri, sets, algorithm]
import parsecfg except Config
import x11/[xlib, x, xutil, keysym]
import ./[state, parser, gui, themes, utils]

# ── Module‑local globals ────────────────────────────────────────────────
var
  currentThemeIndex = 0           ## Active index into `themeList`
  actions*: seq[Action]           ## Current selectable actions

# ── Utility procs ──────────────────────────────────────────────────────
proc runCommand(cmd: string) =
  ## Execute *cmd* in the chosen terminal, else headless.
  let term = chooseTerminal()
  if term.len > 0:
    discard startProcess("/usr/bin/env",
      args = [term, "-e", "sh", "-c", cmd], options = {poDaemon})
  else:
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
        exec:     "xdg-open '" & path & "'",
        hasIcon:  false
      )

# ── Theme helpers ───────────────────────────────────────────────────────
proc applyTheme(cfg: var Config; name: string) =
  ## Apply built‑in theme by name.
  for i, th in themeList:
    if th.name.toLower == name.toLower:
      cfg.bgColorHex          = th.bgColorHex
      cfg.fgColorHex          = th.fgColorHex
      cfg.highlightBgColorHex = th.highlightBgColorHex
      cfg.highlightFgColorHex = th.highlightFgColorHex
      cfg.borderColorHex      = th.borderColorHex
      currentThemeIndex       = i
      return

proc updateParsedColors(cfg: var Config) =
  ## Resolve hex → pixel colours.
  cfg.bgColor          = parseColor(cfg.bgColorHex)
  cfg.fgColor          = parseColor(cfg.fgColorHex)
  cfg.highlightBgColor = parseColor(cfg.highlightBgColorHex)
  cfg.highlightFgColor = parseColor(cfg.highlightFgColorHex)
  cfg.borderColor      = parseColor(cfg.borderColorHex)

proc cycleTheme(cfg: var Config) =
  ## Cycle built‑in theme and redraw.
  currentThemeIndex = (currentThemeIndex + 1) mod themeList.len
  let th = themeList[currentThemeIndex]
  applyTheme(cfg, th.name)
  gui.notifyThemeChanged(th.name)
  updateParsedColors(cfg)
  gui.updateGuiColors()
  gui.redrawWindow()

# ── Applications discovery ──────────────────────────────────────────────
proc loadApplications() =
  let usrDir   = "/usr/share/applications"
  let locDir   = getHomeDir() / ".local/share/applications"
  let cacheDir  = getHomeDir() / ".cache" / "nim_launcher"
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

# ── Configuration loading ──────────────────────────────────────────────
const iniTemplate = """
[window]
width             = 500
max_visible_items = 10
center            = true
position_x        = 20
position_y        = 50
vertical_align    = "one-third"

[font]
fontname = "Noto Sans:size=12"

[input]
prompt = "> "
cursor = "_"

[terminal]
program = "gnome-terminal"

[border]
width = 2

[colors]
background           = "#2E3440"
foreground           = "#D8DEE9"
highlight_background = "#88C0D0"
highlight_foreground = "#2E3440"
border_color         = "#8BE9FD"

[theme]
# name = "Ayu Dark"
"""

proc initLauncherConfig() =
  ## Defaults → override via config.ini
  config = Config()
  config.winWidth            = 500
  config.lineHeight          = 22
  config.maxVisibleItems     = 10
  config.centerWindow        = true
  config.positionX           = 20
  config.positionY           = 50
  config.verticalAlign       = "one-third"
  config.fontName            = "Noto Sans:size=12"
  config.prompt              = "> "
  config.cursor              = "_"
  config.terminalExe         = "gnome-terminal"
  config.bgColorHex          = "#2E3440"
  config.fgColorHex          = "#D8DEE9"
  config.highlightBgColorHex = "#88C0D0"
  config.highlightFgColorHex = "#2E3440"
  config.borderColorHex      = "#8BE9FD"
  config.borderWidth         = 2
  config.themeName           = ""

  let cfgPath = getHomeDir() / ".config" / "nim_launcher" / "config.ini"
  if not fileExists(cfgPath):
    createDir(cfgPath.parentDir)
    writeFile(cfgPath, iniTemplate)
    echo "Created default config at ", cfgPath

  let ini = loadConfig(cfgPath)
  for sec, tbl in ini:
    for key, val in tbl:
      if sec == "window":
        case key
        of "width":               config.winWidth        = val.parseInt
        of "max_visible_items":   config.maxVisibleItems = val.parseInt
        of "center":              config.centerWindow    = val.toLower == "true"
        of "position_x":          config.positionX       = val.parseInt
        of "position_y":          config.positionY       = val.parseInt
        of "vertical_align":      config.verticalAlign   = val
        else: discard
      elif sec == "font" and key == "fontname": config.fontName = val
      elif sec == "input":
        case key
        of "prompt": config.prompt = val
        of "cursor": config.cursor = val
        else: discard
      elif sec == "terminal" and key == "program":
        config.terminalExe = val.strip(chars={'"','\''})
      elif sec == "border" and key == "width":
        config.borderWidth = val.parseInt
      elif sec == "colors":
        case key
        of "background":           config.bgColorHex          = val
        of "foreground":           config.fgColorHex          = val
        of "highlight_background": config.highlightBgColorHex = val
        of "highlight_foreground": config.highlightFgColorHex = val
        of "border_color":         config.borderColorHex      = val
        else: discard
      elif sec == "theme" and key == "name":
        config.themeName = val

  if config.themeName.len > 0: applyTheme(config, config.themeName)
  config.winMaxHeight = 40 + config.maxVisibleItems * config.lineHeight
  echo "Font → ", config.fontName

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
    runCommand(a.exec)
  of akYouTube, akGoogle, akWiki:
    openUrl(a.exec)
  of akConfig, akApp:
    if a.kind == akConfig:
      discard startProcess("/bin/sh", args = ["-c", a.exec], options={poDaemon})
    else:
      discard startProcess("/bin/sh", args = ["-c", a.exec.split('%')[0].strip()], options={poDaemon})
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
  initLauncherConfig()
  loadApplications()
  loadRecent()
  buildActions()
  initGui()
  if benchMode:
    gui.redrawWindow()
    quit 0
  updateParsedColors(config)
  gui.updateGuiColors()

  while not shouldExit:
    var ev: XEvent
    discard XNextEvent(display, ev.addr)
    case ev.theType
    of Expose:            gui.redrawWindow()
    of KeyPress:          
      handleKeyPress(ev); 
      if not shouldExit: 
        gui.redrawWindow()
    of FocusOut:          shouldExit = true
    else: discard

  discard XDestroyWindow(display, window)
  discard XCloseDisplay(display)

when isMainModule:
  main()
