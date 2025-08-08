# src/nLauncher.nim
## nLauncher.nim — main program with Action abstraction and fixes
## MIT; see LICENSE for details.
## Requires Nim ≥ 2.0 with x11 & xft packages.
## Startup in --bench mode still completes in ~1–2 ms on a modern system.

# ── Imports ─────────────────────────────────────────────────────────────
import std/[os, osproc, strutils, options, tables, sequtils,
             json, times, uri, sets, algorithm]
import parsetoml as toml
import x11/[xlib, x, xutil, keysym]
import ./[state, parser, gui, utils]

# ── Module-local globals ────────────────────────────────────────────────
var
  currentThemeIndex = 0           ## Active index into `themeList`
  actions*: seq[Action]           ## Current selectable actions

# ── Utility procs ──────────────────────────────────────────────────────
proc splitArgs(s: string): seq[string] =
  var cur = newStringOfCap(16); var q = '\0'
  for c in s:
    if q == '\0':
      case c
      of ' ', '\t':
        if cur.len > 0: result.add cur; cur.setLen(0)
      of '"', '\'': q = c
      else: cur.add c
    else:
      if c == q: q = '\0' else: cur.add c
  if cur.len > 0: result.add cur

proc hasHoldFlag(args: seq[string]): bool =
  for a in args:
    if a == "--hold" or a == "--keep-open":
      return true
  false

proc runCommand(cmd: string) =
  let bash = findExe("bash")
  let shExe = if bash.len > 0: bash else: "/bin/sh"

  var parts = splitArgs(chooseTerminal())
  if parts.len == 0:
    # headless
    let fullCmd = cmd & "; echo; echo '[Press Enter to close]'; read _"
    let shArgs = (if shExe.endsWith("bash"): @["-lc", fullCmd] else: @["-c", fullCmd])
    discard startProcess(shExe, args = shArgs, options = {poDaemon})
    return

  let exe = parts[0]
  let exePath = findExe(exe)
  if exePath.len == 0:
    let fullCmd = cmd & "; echo; echo '[Press Enter to close]'; read _"
    let shArgs = (if shExe.endsWith("bash"): @["-lc", fullCmd] else: @["-c", fullCmd])
    discard startProcess(shExe, args = shArgs, options = {poDaemon})
    return

  var termArgs = (if parts.len > 1: parts[1..^1] else: @[])
  let base = exe.extractFilename()
  let hold = hasHoldFlag(termArgs)

  # If the terminal will hold the window, skip adding `read _`
  let fullCmd =
    if hold: cmd
    else:    cmd & "; echo; echo '[Press Enter to close]'; read _"

  let shArgs = (if shExe.endsWith("bash"): @["-lc", fullCmd] else: @["-c", fullCmd])

  # Build argv per terminal
  if base == "gnome-terminal" or base == "kgx":
    termArgs.add "--"
    termArgs.add shExe
    for a in shArgs: termArgs.add a
  elif base == "wezterm":
    termArgs = @["start"] & termArgs
    termArgs.add shExe
    for a in shArgs: termArgs.add a
  elif base == "kitty":
    # compat path proved most reliable
    termArgs.add "-e"
    termArgs.add shExe
    for a in shArgs: termArgs.add a
  else:
    # xterm-style (alacritty, foot, konsole, xfce4-terminal, xterm…)
    termArgs.add "-e"
    termArgs.add shExe
    for a in shArgs: termArgs.add a

  discard startProcess(exePath, args = termArgs, options = {poDaemon})


proc openUrl(url: string) =
  ## Open *url* via xdg-open without a shell (quote-safe).
  discard startProcess("/usr/bin/env",
    args = @["xdg-open", url],
    options = {poDaemon})

proc scanConfigFiles*(query: string): seq[DesktopApp] =
  ## Return config files matching *query*.
  let base = getHomeDir() / ".config"
  let ql = query.toLowerAscii
  for path in walkDirRec(base):
    if fileExists(path):
      let fn = path.extractFilename
      if fn.len > 0 and fn.toLowerAscii.contains(ql):
        result.add DesktopApp(
          name:     fn,
          exec:     "xdg-open " & shellQuote(path),
          hasIcon:  false
        )

# ── Theme helpers ───────────────────────────────────────────────────────
proc applyTheme*(cfg: var Config; name: string) =
  for i, th in themeList:
    if th.name.toLower == name.toLower:
      cfg.bgColorHex          = th.bgColorHex
      cfg.fgColorHex          = th.fgColorHex
      cfg.highlightBgColorHex = th.highlightBgColorHex
      cfg.highlightFgColorHex = th.highlightFgColorHex
      cfg.borderColorHex      = th.borderColorHex

      # NEW: theme-owned match color selection
      let m = th.matchFgColorHex.toLowerAscii
      if m.len > 0 and m != "auto":
        cfg.matchFgColorHex = th.matchFgColorHex
      else:
        # derive from theme accents, fallback to amber
        cfg.matchFgColorHex = pickAccentColor(
          cfg.bgColorHex, cfg.fgColorHex, cfg.highlightBgColorHex, cfg.highlightFgColorHex
        )

      cfg.themeName     = th.name
      currentThemeIndex = i
      return




proc updateParsedColors(cfg: var Config) =
  ## Resolve hex → pixel colours.
  cfg.bgColor          = parseColor(cfg.bgColorHex)
  cfg.fgColor          = parseColor(cfg.fgColorHex)
  cfg.highlightBgColor = parseColor(cfg.highlightBgColorHex)
  cfg.highlightFgColor = parseColor(cfg.highlightFgColorHex)
  cfg.borderColor      = parseColor(cfg.borderColorHex)

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
  currentThemeIndex = (currentThemeIndex + 1) mod themeList.len
  let th = themeList[currentThemeIndex]
  applyTheme(cfg, th.name)
  gui.notifyThemeChanged(th.name)
  updateParsedColors(cfg)
  gui.updateGuiColors()
  gui.redrawWindow()
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
  config = Config()  # zero-init

  # In-code defaults (fallbacks)
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
  config.terminalExe     = "gnome-terminal"   # current default kept
  config.borderWidth     = 2
  config.matchFgColorHex = "#f8c291"

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
      borderColorHex:      th["borderColorHex"].getStr(""),
      matchFgColorHex:     th.getOrDefault("matchFgColorHex").getStr("")
    )

  # ── last_chosen ────────────────────────────────────────────────────────
  let lastName = tbl["theme"]["last_chosen"].getStr("")
  var pickedIndex = -1

  # Try to find the saved theme in the list (case-insensitive)
  if lastName.len > 0:
    for i, th in themeList:
      if th.name.toLowerAscii == lastName.toLowerAscii:
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

proc subseqSpans(q, t: string): seq[(int,int)] =
  ## Return 1-char spans in t matching q as a subsequence (case-insensitive).
  if q.len == 0 or t.len == 0: return @[]
  let lq = q.toLowerAscii
  let lt = t.toLowerAscii
  var qi = 0
  for i in 0 ..< lt.len:
    if qi < lq.len and lt[i] == lq[qi]:
      result.add (i, 1)
      inc qi
      if qi == lq.len: break


# ── Fuzzy match helper ─────────────────────────────────────────────────
# Return positions of q matched as subsequence in t (lowercase), or @[] if no match
proc subseqPositions(q, t: string): seq[int] =
  if q.len == 0: return @[]
  let lq = q.toLowerAscii
  let lt = t.toLowerAscii
  var qi = 0
  for i, ch in lt:
    if qi < lq.len and ch == lq[qi]:
      result.add i
      inc qi
      if qi == lq.len: break
  if result.len != lq.len: result.setLen(0)

proc isWordBoundary(lt: string; idx: int): bool =
  if idx <= 0: return true
  let c = lt[idx-1]
  return c == ' ' or c == '-' or c == '_' or c == '.' or c == '/'

# Compute a score for how well t matches q; higher is better. Returns (score, positions)
proc scoreMatch(q, t: string): (int, seq[int]) =
  if q.len == 0: return (0, @[])
  let lq = q.toLowerAscii
  let lt = t.toLowerAscii

  # Exact substring gets big boost
  let pos = lt.find(lq)
  if pos >= 0:
    var s = 1000
    if pos == 0: s += 200                       # prefix bonus
    if isWordBoundary(lt, pos): s += 80         # word boundary start
    s += max(0, 60 - (t.len - q.len))           # shorter names a bit higher
    return (s, toSeq(pos ..< pos + lq.len))

  # Otherwise, subsequence
  let posns = subseqPositions(q, t)
  if posns.len == 0: return (-1_000_000, @[])   # not a match

  var score = 0
  # Consecutive streak bonus
  var longest = 1
  var cur = 1
  for i in 1 ..< posns.len:
    if posns[i] == posns[i-1] + 1:
      inc cur
      if cur > longest: longest = cur
    else:
      cur = 1
  score += longest * 25

  # Gap penalty (prefer tighter matches)
  var gaps = 0
  for i in 1 ..< posns.len:
    gaps += (posns[i] - posns[i-1] - 1)
  score -= gaps * 3

  # Word-boundary bonus for each matched char at a word start
  for p in posns:
    if isWordBoundary(lt, p): score += 8

  # First char at start bonus
  if posns[0] == 0: score += 25

  # Light length bias
  score += max(0, 40 - (t.len - q.len))

  (score, posns)

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
      # MRU first, then the rest (unchanged)
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
      # ── SMART FUZZY: rank by score ─────────────────────────────────────
      var ranked: seq[(int, Action)] = @[]
      for app in allApps:
        let (s, _) = scoreMatch(inputText, app.name)     # <- add scoreMatch proc separately
        if s > -1_000_000:                                # keep only matches
          ranked.add (s, Action(kind: akApp, label: app.name, exec: app.exec, appData: app))
      ranked.sort(proc(a, b: (int, Action)): int =
        result = cmp(b[0], a[0])                          # score desc
        if result == 0: result = cmpIgnoreCase(a[1].label, b[1].label)  # tiebreak by name
      )
      actions.setLen(0)
      for it in ranked: actions.add it[1]

    # Mirror to filteredApps + compute highlight spans
  filteredApps = @[]
  matchSpans   = @[]

  # Derive the visible query (strip trigger prefix for highlighting)
  let isSlash = inputText.startsWith("/")
  var q = inputText
  if isSlash:
    if inputText.startsWith("/c ") or inputText.startsWith("/g ") or
       inputText.startsWith("/y ") or inputText.startsWith("/w "):
      q = inputText[3..^1].strip()
    else:
      q = (if inputText.len > 1: inputText[1..^1].strip() else: "")

  for act in actions:
    filteredApps.add DesktopApp(
      name:    act.label,
      exec:    act.exec,
      hasIcon: (act.kind == akApp and act.appData.hasIcon)
    )

    if inputText.len == 0 or q.len == 0:
      matchSpans.add @[]
    else:
      case act.kind
      of akApp, akConfig:
        # normal list items: fuzzy against the visible query
        matchSpans.add subseqSpans(q, act.label)

      of akYouTube, akGoogle, akWiki:
        # labels look like "Search X: " & q — fuzzy only within the query tail
        let off = max(0, act.label.len - q.len)
        let seg = if off < act.label.len: act.label[off .. ^1] else: ""
        let spansRel = subseqSpans(q, seg)
        var spansAbs: seq[(int,int)] = @[]
        for (s, l) in spansRel: spansAbs.add (off + s, l)
        matchSpans.add spansAbs

      of akRun:
        # label is "Run: " & q — fuzzy only within the command part
        const prefix = "Run: "
        let off = if act.label.len >= prefix.len: prefix.len else: 0
        let seg = if off < act.label.len: act.label[off .. ^1] else: ""
        let spansRel = subseqSpans(q, seg)
        var spansAbs: seq[(int,int)] = @[]
        for (s, l) in spansRel: spansAbs.add (off + s, l)
        matchSpans.add spansAbs

  selectedIndex = 0
  viewOffset    = 0



# ── Perform selected action ─────────────────────────────────────────────
proc performAction(a: Action) =
  case a.kind
  of akRun:
    runCommand(a.exec)
  of akYouTube, akGoogle, akWiki:
    openUrl(a.exec)
  of akConfig:
    discard startProcess("/bin/sh", args = ["-c", a.exec], options={poDaemon})
  of akApp:
    discard startProcess("/bin/sh", args = ["-c", a.exec.split('%')[0].strip()], options={poDaemon})
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
      if ev.xmap.window == window:
        seenMapNotify = true
    of Expose:
      gui.redrawWindow()
    of KeyPress:
      handleKeyPress(ev)
      if not shouldExit:
        gui.redrawWindow()
    of ButtonPress:
      shouldExit = true
    of FocusOut:
      if seenMapNotify:
        seenMapNotify = false
      else:
        shouldExit = true
    else:
      discard

  discard XDestroyWindow(display, window)
  discard XCloseDisplay(display)

when isMainModule:
  main()
