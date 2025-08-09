## nLauncher.nim — main program (lean: no /f file search)
## MIT; see LICENSE for details.

# ── Imports ─────────────────────────────────────────────────────────────
import std/[os, osproc, strutils, options, tables, sequtils, json, uri, sets,
    algorithm, times, heapqueue]
import parsetoml as toml
import x11/[xlib, x, xutil, keysym]
import ./[state, parser, gui, utils]

# ── Module-local globals ────────────────────────────────────────────────
var
  currentThemeIndex = 0 ## active theme index in `themeList`
  actions*: seq[Action] ## transient list for the UI

# ── Shell / process helpers ─────────────────────────────────────────────
proc hasHoldFlagLocal(args: seq[string]): bool =
  ## Detect common "keep window open" flags passed to terminals.
  for a in args:
    case a
    of "--hold", "-hold", "--keep-open", "--wait", "--noclose",
       "--stay-open", "--keep", "--keepalive":
      return true
    else:
      discard
  false

proc buildTerminalArgs(base: string; termArgs: seq[string]; shExe: string;
    shArgs: seq[string]): seq[string] =
  ## Normalize command-line to launch a shell inside major terminals.
  var argv = termArgs
  case base
  of "gnome-terminal", "kgx":
    argv.add "--"; argv.add shExe; for a in shArgs: argv.add a
  of "wezterm":
    argv = @["start"] & argv; argv.add shExe; for a in shArgs: argv.add a
  of "kitty":
    argv.add "-e"; argv.add shExe; for a in shArgs: argv.add a
  else:
    argv.add "-e"; argv.add shExe; for a in shArgs: argv.add a
  argv

proc buildShellCommand(cmd, shExe: string; hold = false):
  tuple[fullCmd: string, shArgs: seq[string]] =
  ## Append hold helper and construct shell arguments.
  let fullCmd = if hold: cmd else: cmd & "; echo; echo '[Press Enter to close]'; read _"
  let shArgs = if shExe.endsWith("bash"): @["-lc", fullCmd] else: @["-c", fullCmd]
  (fullCmd, shArgs)

proc runCommand(cmd: string) =
  ## Run `cmd` in the user's terminal; fall back to /bin/sh if none.
  let bash = findExe("bash")
  let shExe = if bash.len > 0: bash else: "/bin/sh"

  var parts = tokenize(chooseTerminal()) # parser.tokenize
  if parts.len == 0:
    let (_, shArgs) = buildShellCommand(cmd, shExe)
    discard startProcess(shExe, args = shArgs, options = {poDaemon})
    return

  let exe = parts[0]
  let exePath = findExe(exe)
  if exePath.len == 0:
    let (_, shArgs) = buildShellCommand(cmd, shExe)
    discard startProcess(shExe, args = shArgs, options = {poDaemon})
    return

  var termArgs = if parts.len > 1: parts[1..^1] else: @[]
  let base = exe.extractFilename()

  let hold = hasHoldFlagLocal(termArgs)
  let (_, shArgs) = buildShellCommand(cmd, shExe, hold)
  let argv = buildTerminalArgs(base, termArgs, shExe, shArgs)

  discard startProcess(exePath, args = argv, options = {poDaemon})

proc openUrl(url: string) =
  ## Open *url* via xdg-open (no shell involved).
  discard startProcess("/usr/bin/env", args = @["xdg-open", url], options = {poDaemon})

# ── Small searches: ~/.config helper ────────────────────────────────────
proc scanConfigFiles*(query: string): seq[DesktopApp] =
  ## Return entries from ~/.config matching `query` (case-insensitive).
  let base = getHomeDir() / ".config"
  let ql = query.toLowerAscii
  for path in walkDirRec(base):
    if fileExists(path):
      let fn = path.extractFilename
      if fn.len > 0 and fn.toLowerAscii.contains(ql):
        result.add DesktopApp(
          name: fn,
          exec: "xdg-open " & shellQuote(path),
          hasIcon: false
        )

# ── Theme helpers ───────────────────────────────────────────────────────
proc applyTheme*(cfg: var Config; name: string) =
  ## Set theme fields from `themeList` by name; respect explicit match color.
  for i, th in themeList:
    if th.name.toLowerAscii == name.toLowerAscii:
      cfg.bgColorHex = th.bgColorHex
      cfg.fgColorHex = th.fgColorHex
      cfg.highlightBgColorHex = th.highlightBgColorHex
      cfg.highlightFgColorHex = th.highlightFgColorHex
      cfg.borderColorHex = th.borderColorHex
      if th.matchFgColorHex.len > 0:
        cfg.matchFgColorHex = th.matchFgColorHex
      cfg.themeName = th.name
      currentThemeIndex = i
      break

proc updateParsedColors(cfg: var Config) =
  ## Resolve hex → pixel colours used by Xft/Xlib.
  cfg.bgColor = parseColor(cfg.bgColorHex)
  cfg.fgColor = parseColor(cfg.fgColorHex)
  cfg.highlightBgColor = parseColor(cfg.highlightBgColorHex)
  cfg.highlightFgColor = parseColor(cfg.highlightFgColorHex)
  cfg.borderColor = parseColor(cfg.borderColorHex)

proc applyThemeAndColors*(cfg: var Config; name: string; doNotify = true) =
  ## Apply theme, resolve colors, push to GUI, and optionally redraw.
  applyTheme(cfg, name)
  updateParsedColors(cfg)
  gui.updateGuiColors()
  if doNotify:
    gui.notifyThemeChanged(name)
    gui.redrawWindow()

proc saveLastTheme(cfgPath: string) =
  ## Update or insert [theme].last_chosen = "<name>" in the TOML file.
  var lines = readFile(cfgPath).splitLines()
  var inTheme = false
  var updated = false
  var themeSectionFound = false
  for i in 0..<lines.len:
    let l = lines[i].strip()
    if l == "[theme]":
      inTheme = true
      themeSectionFound = true
      continue
    if inTheme:
      if l.startsWith("[") and l.endsWith("]"):
        lines.insert("last_chosen = \"" & config.themeName & "\"", i)
        updated = true
        break
      if l.startsWith("last_chosen"):
        lines[i] = "last_chosen = \"" & config.themeName & "\""
        updated = true
        break
  if not themeSectionFound:
    lines.add("")
    lines.add("[theme]")
    lines.add("last_chosen = \"" & config.themeName & "\"")
    updated = true
  if updated:
    writeFile(cfgPath, lines.join("\n"))

proc cycleTheme*(cfg: var Config) =
  ## Cycle to the next theme in `themeList` and persist the choice.
  currentThemeIndex = (currentThemeIndex + 1) mod themeList.len
  let th = themeList[currentThemeIndex]
  applyThemeAndColors(cfg, th.name)
  saveLastTheme(getHomeDir() / ".config" / "nlauncher" / "nlauncher.toml")


# ── Applications discovery (.desktop) ───────────────────────────────────
proc loadApplications() =
  ## Scan .desktop files with caching to ~/.cache/nlauncher/apps.json.
  let usrDir = "/usr/share/applications"
  let locDir = getHomeDir() / ".local/share/applications"
  let cacheDir = getHomeDir() / ".cache" / "nlauncher"
  let cacheFile = cacheDir / "apps.json"

  let usrM = if dirExists(usrDir): times.toUnix(getLastModificationTime(
      usrDir)) else: 0'i64
  let locM = if dirExists(locDir): times.toUnix(getLastModificationTime(
      locDir)) else: 0'i64

  if fileExists(cacheFile):
    try:
      let c = to(parseJson(readFile(cacheFile)), CacheData)
      if c.usrMtime == usrM and c.localMtime == locM:
        timeIt "Cache hit:":
          allApps = c.apps
          filteredApps = allApps
        return
    except:
      echo "Cache miss — rescanning …"

  timeIt "Full scan:":
    var dedup = initTable[string, DesktopApp]()
    for dir in @[locDir, usrDir]:
      if not dirExists(dir): continue
      for path in walkFiles(dir / "*.desktop"):
        let opt = parseDesktopFile(path)
        if isSome(opt): # ← prefix call (or: if opt.isSome()):
          let app = get(opt) # ← prefix call (or: let app = opt.get())
          let key = getBaseExec(app.exec)
          if not dedup.hasKey(key) or (app.hasIcon and not dedup[key].hasIcon):
            dedup[key] = app


    allApps = dedup.values.toSeq
    allApps.sort(proc(a, b: DesktopApp): int = cmpIgnoreCase(a.name, b.name))
    filteredApps = allApps
    try:
      createDir(cacheDir)
      writeFile(cacheFile, pretty(%CacheData(usrMtime: usrM, localMtime: locM,
          apps: allApps)))
    except:
      echo "Warning: cache not saved."

# ── Load & apply config from TOML ───────────────────────────────────────
proc initLauncherConfig() =
  ## Initialize defaults, read TOML, apply last theme, compute geometry.
  config = Config() # zero-init

  # In-code defaults
  config.winWidth = 500
  config.lineHeight = 22
  config.maxVisibleItems = 10
  config.centerWindow = true
  config.positionX = 20
  config.positionY = 50
  config.verticalAlign = "one-third"
  config.fontName = "Noto Sans:size=12"
  config.prompt = "> "
  config.cursor = "_"
  config.terminalExe = "gnome-terminal"
  config.borderWidth = 2
  config.matchFgColorHex = "#f8c291"

  # Ensure TOML exists
  let cfgDir = getHomeDir() / ".config" / "nlauncher"
  let cfgPath = cfgDir / "nlauncher.toml"
  if not fileExists(cfgPath):
    createDir(cfgDir)
    writeFile(cfgPath, defaultToml)
    echo "Created default config at ", cfgPath

  # Parse TOML
  let tbl = toml.parseFile(cfgPath)

  # window
  let w = tbl["window"]
  config.winWidth = w["width"].getInt(config.winWidth)
  config.maxVisibleItems = w["max_visible_items"].getInt(config.maxVisibleItems)
  config.centerWindow = w["center"].getBool(config.centerWindow)
  config.positionX = w["position_x"].getInt(config.positionX)
  config.positionY = w["position_y"].getInt(config.positionY)
  config.verticalAlign = w["vertical_align"].getStr(config.verticalAlign)

  # font
  let f = tbl["font"]
  config.fontName = f["fontname"].getStr(config.fontName)

  # input
  let inp = tbl["input"]
  config.prompt = inp["prompt"].getStr(config.prompt)
  config.cursor = inp["cursor"].getStr(config.cursor)

  # terminal
  let term = tbl["terminal"]
  config.terminalExe = term["program"].getStr(config.terminalExe)

  # border
  let b = tbl["border"]
  config.borderWidth = b["width"].getInt(config.borderWidth)

  # themes
  themeList = @[]
  for thVal in tbl["themes"].getElems():
    let th = thVal.getTable()
    themeList.add Theme(
      name: th["name"].getStr(""),
      bgColorHex: th["bgColorHex"].getStr(""),
      fgColorHex: th["fgColorHex"].getStr(""),
      highlightBgColorHex: th["highlightBgColorHex"].getStr(""),
      highlightFgColorHex: th["highlightFgColorHex"].getStr(""),
      borderColorHex: th["borderColorHex"].getStr(""),
      matchFgColorHex: th.getOrDefault("matchFgColorHex").getStr("")
    )

  # last_chosen (case-insensitive match; fallback to first theme)
  let lastName = tbl["theme"]["last_chosen"].getStr("")
  var pickedIndex = -1
  if lastName.len > 0:
    for i, th in themeList:
      if th.name.toLowerAscii == lastName.toLowerAscii:
        pickedIndex = i
        break
  if pickedIndex < 0:
    if themeList.len > 0: pickedIndex = 0
    else: quit("nLauncher error: no themes defined in nlauncher.toml")

  let chosen = themeList[pickedIndex].name
  config.themeName = chosen
  applyTheme(config, chosen)
  if chosen != lastName:
    saveLastTheme(cfgPath)

  # derived geometry
  config.winMaxHeight = 40 + config.maxVisibleItems * config.lineHeight

# ── Fuzzy match + helpers ───────────────────────────────────────────────
proc recentBoost(name: string): int =
  ## Small score bonus for recently used apps (first is strongest).
  let idx = recentApps.find(name)
  if idx >= 0: return max(0, 200 - idx * 40)
  0

proc takePrefix(input, pfx: string; rest: var string): bool =
  ## Consume a command prefix and return the remainder (trimmed).
  let n = pfx.len
  if input.len >= n and input[0..n-1] == pfx:
    if input.len == n:
      rest = ""
      return true
    if input.len > n:
      if input[n] == ' ':
        rest = input[n+1 .. ^1].strip()
        return true
      rest = input[n .. ^1].strip()
      return true
  false

proc subseqPositions(q, t: string): seq[int] =
  ## Case-insensitive subsequence positions of q within t (for highlight).
  if q.len == 0: return @[]
  let lq = q.toLowerAscii
  let lt = t.toLowerAscii
  var qi = 0
  for i in 0 ..< lt.len:
    if qi < lq.len and lt[i] == lq[qi]:
      result.add i
      inc qi
      if qi == lq.len:
        return
  result.setLen(0)

proc subseqSpans(q, t: string): seq[(int, int)] =
  ## Convert positions to 1-char spans for highlighting.
  for p in subseqPositions(q, t):
    result.add (p, 1)

proc isWordBoundary(lt: string; idx: int): bool =
  ## Basic token boundary check for nicer scoring.
  if idx <= 0: return true
  let c = lt[idx-1]
  c == ' ' or c == '-' or c == '_' or c == '.' or c == '/'

proc scoreMatch(q, t, fullPath, home: string): int =
  ## Heuristic score for matching q against t (higher is better).
  if q.len == 0: return -1_000_000
  let lq = q.toLowerAscii
  let lt = t.toLowerAscii
  let pos = lt.find(lq)

  var s = -1_000_000
  if pos >= 0:
    s = 1000
    if pos == 0: s += 200
    if isWordBoundary(lt, pos): s += 80
    s += max(0, 60 - (t.len - q.len))

  if t == q: s += 9000
  elif t.toLowerAscii == lq: s += 8600
  elif lt.startsWith(lq): s += 8200
  elif lt.contains(lq): s += 7800

  if fullPath.startsWith(home & "/"):
    if t.toLowerAscii == lq: s += 600
    elif t.toLowerAscii.startsWith(lq): s += 400
  s

# ── Web shortcuts ───────────────────────────────────────────────────────
type WebSpec = tuple[prefix, label, base: string; kind: ActionKind]
const webSpecs: array[3, WebSpec] = [
  ("/y", "Search YouTube: ", "https://www.youtube.com/results?search_query=",
      akYouTube),
  ("/g", "Search Google: ", "https://www.google.com/search?q=", akGoogle),
  ("/w", "Search Wiki: ", "https://en.wikipedia.org/wiki/Special:Search?search=", akWiki)
]

proc visibleQuery(inputText: string): string =
  ## Return the user's query sans command prefix so highlight works.
  ## Handles: /c, /t, web specs (/y,/g,/w), and generic "/".
  ## Must stay in sync with buildActions.
  if not inputText.startsWith("/"):
    return inputText

  var rest: string

  if takePrefix(inputText, "/c", rest):
    return rest
  if takePrefix(inputText, "/t", rest):
    return rest

  for spec in webSpecs:
    if takePrefix(inputText, spec.prefix, rest):
      return rest

  if takePrefix(inputText, "/", rest):
    return rest

  ""

# ── Build actions & mirror to filteredApps ─────────────────────────────
proc buildActions() =
  ## Populate `actions` based on `inputText`; mirror to GUI lists/spans.
  actions.setLen(0)

  var handled = false
  var rest: string

  # /t — theme preview / chooser (stays in-place on Enter)
  if (not handled) and inputText.startsWith("/t"):
    rest = inputText[2..^1].strip()
    let ql = rest.toLowerAscii
    for th in themeList:
      if ql.len == 0 or th.name.toLowerAscii.contains(ql):
        actions.add Action(kind: akTheme, label: th.name, exec: th.name)
    handled = true


  # /c — search files under ~/.config
  if (not handled) and takePrefix(inputText, "/c", rest):
    for a in scanConfigFiles(rest):
      actions.add Action(kind: akConfig, label: a.name, exec: a.exec)
    handled = true

  # /y, /g, /w — web searches
  if not handled:
    for spec in webSpecs:
      if takePrefix(inputText, spec.prefix, rest):
        actions.add Action(kind: spec.kind,
                           label: spec.label & rest,
                           exec: spec.base & encodeUrl(rest))
        handled = true
        break

  # "/" — raw run (only if not a known mode)
  if (not handled) and inputText.startsWith("/") and inputText.len > 1 and
     not inputText.startsWith("/t") and
     not inputText.startsWith("/c") and
     not inputText.startsWith("/y") and
     not inputText.startsWith("/g") and
     not inputText.startsWith("/w"):
    let cmd = inputText[1..^1].strip()
    actions.add Action(kind: akRun, label: "Run: " & cmd, exec: cmd)
    handled = true

  # Default view — app list (MRU first, then fuzzy)
  if not handled:
    if inputText.len == 0:
      var seen = initHashSet[string]()
      for name in recentApps:
        for app in allApps:
          if app.name == name:
            actions.add Action(kind: akApp, label: app.name, exec: app.exec, appData: app)
            seen.incl name
            break
      for app in allApps:
        if not seen.contains(app.name):
          actions.add Action(kind: akApp, label: app.name, exec: app.exec, appData: app)
    else:
      var top = initHeapQueue[(int, Action)]()
      let limit = config.maxVisibleItems
      for app in allApps:
        let s = scoreMatch(inputText, app.name, app.name, "")
        if s > -1_000_000:
          push(top, (s + recentBoost(app.name),
                     Action(kind: akApp, label: app.name, exec: app.exec, appData: app)))
          if top.len > limit:
            discard pop(top)
      var ranked: seq[(int, Action)] = @[]
      while top.len > 0:
        ranked.add pop(top)
      ranked.sort(proc(a, b: (int, Action)): int =
        result = cmp(b[0], a[0])
        if result == 0: result = cmpIgnoreCase(a[1].label, b[1].label)
      )
      actions.setLen(0)
      for it in ranked: actions.add it[1]

  # Mirror to filteredApps + highlight spans
  filteredApps = @[]
  matchSpans = @[]

  let q = visibleQuery(inputText)
  for act in actions:
    filteredApps.add DesktopApp(
      name: act.label,
      exec: act.exec,
      hasIcon: (act.kind == akApp and act.appData.hasIcon)
    )
    if inputText.len == 0 or q.len == 0:
      matchSpans.add @[]
    else:
      case act.kind
      of akApp, akConfig, akTheme:
        matchSpans.add subseqSpans(q, act.label)
      of akYouTube, akGoogle, akWiki:
        let off = max(0, act.label.len - q.len)
        let seg = if off < act.label.len: act.label[off .. ^1] else: ""
        var spansAbs: seq[(int, int)] = @[]
        for (s, l) in subseqSpans(q, seg): spansAbs.add (off + s, l)
        matchSpans.add spansAbs
      of akRun:
        const prefix = "Run: "
        let off = if act.label.len >= prefix.len: prefix.len else: 0
        let seg = if off < act.label.len: act.label[off .. ^1] else: ""
        var spansAbs: seq[(int, int)] = @[]
        for (s, l) in subseqSpans(q, seg): spansAbs.add (off + s, l)
        matchSpans.add spansAbs

  selectedIndex = 0
  viewOffset = 0

# ── Perform selected action ─────────────────────────────────────────────
proc performAction(a: Action) =
  var exitAfter = true ## default: exit after action
  case a.kind
  of akRun:
    runCommand(a.exec)
  of akYouTube, akGoogle, akWiki:
    openUrl(a.exec)
  of akConfig:
    discard startProcess("/bin/sh", args = ["-c", a.exec], options = {poDaemon})
  of akApp:
    discard startProcess("/bin/sh", args = ["-c", a.exec.split('%')[0].strip()],
                         options = {poDaemon})
    if a.label in recentApps:
      recentApps.delete(recentApps.find(a.label))
    recentApps.insert(a.label, 0)
    if recentApps.len > maxRecent: recentApps.setLen(maxRecent)
    saveRecent()
  of akTheme:
    ## Apply and persist, but DO NOT reset selection or exit.
    applyThemeAndColors(config, a.exec) # a.exec carries the theme name
    saveLastTheme(getHomeDir() / ".config" / "nlauncher" / "nlauncher.toml")
    exitAfter = false
  # no `else`: all cases covered
  if exitAfter:
    shouldExit = true


# ── Main loop ───────────────────────────────────────────────────────────
proc main() =
  benchMode = "--bench" in commandLineParams()

  timeIt "Init Config:": initLauncherConfig()
  timeIt "Load Applications:": loadApplications()
  timeIt "Load Recent Apps:": loadRecent()
  timeIt "Build Actions:": buildActions()

  initGui()

  timeIt "updateParsedColors:": updateParsedColors(config)
  timeIt "updateGuiColors:": gui.updateGuiColors()
  timeIt "Benchmark(Redraw Frame):": gui.redrawWindow()

  if benchMode: quit 0

  while not shouldExit:
    if XPending(display) == 0:
      sleep(10)
      continue

    var ev: XEvent
    discard XNextEvent(display, ev.addr)
    case ev.theType
    of MapNotify:
      if ev.xmap.window == window: seenMapNotify = true
    of Expose:
      gui.redrawWindow()
    of KeyPress:
      var buf: array[40, char]
      var ks: KeySym
      discard XLookupString(ev.xkey.addr, cast[cstring](buf[0].addr), buf.len.cint,
                            ks.addr, nil)
      case ks
      of XK_Escape:
        shouldExit = true

      of XK_Return:
        if selectedIndex in 0..<actions.len:
          performAction(actions[selectedIndex])

      of XK_BackSpace, XK_Left:
        ## Backspace: remove last char. Also map Left→Backspace so you can
        ## quickly “go backwards” to fix a typo without needing Delete.
        if inputText.len > 0:
          inputText.setLen(inputText.len - 1)
          buildActions()

      of XK_Right:
        ## No-op for now (we don’t support mid-string cursor editing yet).
        discard

      of XK_Up:
        if selectedIndex > 0:
          dec selectedIndex
          if selectedIndex < viewOffset: viewOffset = selectedIndex

      of XK_Down:
        if selectedIndex < filteredApps.len - 1:
          inc selectedIndex
          if selectedIndex >= viewOffset + config.maxVisibleItems:
            viewOffset = selectedIndex - config.maxVisibleItems + 1

      of XK_Page_Up:
        ## Jump up by one page (maxVisibleItems).
        if filteredApps.len > 0:
          let step = max(1, config.maxVisibleItems)
          selectedIndex = max(0, selectedIndex - step)
          viewOffset = max(0, viewOffset - step)

      of XK_Page_Down:
        ## Jump down by one page (maxVisibleItems).
        if filteredApps.len > 0:
          let step = max(1, config.maxVisibleItems)
          selectedIndex = min(filteredApps.len - 1, selectedIndex + step)
          let bottom = viewOffset + config.maxVisibleItems - 1
          if selectedIndex > bottom:
            viewOffset = min(selectedIndex, filteredApps.len - 1) - (
                config.maxVisibleItems - 1)
            if viewOffset < 0: viewOffset = 0

      of XK_Home:
        ## Go to the first result.
        if filteredApps.len > 0:
          selectedIndex = 0
          viewOffset = 0

      of XK_End:
        ## Go to the last result.
        if filteredApps.len > 0:
          selectedIndex = filteredApps.len - 1
          viewOffset = max(0, filteredApps.len - config.maxVisibleItems)

      of XK_F5:
        cycleTheme(config)

      else:
        if buf[0] != '\0' and buf[0] >= ' ':
          inputText.add(buf[0])
          buildActions()

      if not shouldExit:
        gui.redrawWindow()

    of ButtonPress:
      shouldExit = true
    of FocusOut:
      if seenMapNotify: seenMapNotify = false
      else: shouldExit = true
    else:
      discard

  discard XDestroyWindow(display, window)
  discard XCloseDisplay(display)

when isMainModule:
  main()
