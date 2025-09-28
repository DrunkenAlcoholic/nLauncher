## nLauncher.nim — main program
## MIT; see LICENSE for details.

# ── Imports ─────────────────────────────────────────────────────────────
import std/[os, osproc, strutils, options, tables, sequtils, json, uri, sets,
            algorithm, times, heapqueue, streams]
import parsetoml as toml
import x11/[xlib, xutil, x, keysym]
import ./[state, parser, gui, utils]

# ── Module-local globals ────────────────────────────────────────────────
var
  currentThemeIndex = 0        ## active theme index in `themeList`
  actions*: seq[Action]        ## transient list for the UI
  lastInputChangeMs = 0'i64    ## updated on each keystroke
  lastSearchBuildMs = 0'i64    ## idle-loop guard to rebuild after debounce
  lastSearchQuery = ""         ## cache key for s: queries
  lastSearchResults: seq[string] = @[] ## cached paths for narrowing queries
  baseMatchFgColorHex = ""     ## default fallback for match highlight colour

const
  SearchDebounceMs = 240     # debounce for s: while typing (unified)
  SearchFdCap      = 800     # cap external search results from fd/locate
  SearchShowCap    = 250     # cap items we score per rebuild

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

proc appendShellArgs(argv: var seq[string]; shExe: string; shArgs: seq[string]) =
  ## Append shell executable and its arguments to `argv`.
  argv.add shExe
  for a in shArgs: argv.add a

proc buildTerminalArgs(base: string; termArgs: seq[string]; shExe: string;
                       shArgs: seq[string]): seq[string] =
  ## Normalize command-line to launch a shell inside major terminals.
  var argv = termArgs
  case base
  of "gnome-terminal", "kgx":
    argv.add "--"
  of "wezterm":
    argv = @["start"] & argv
  else:
    argv.add "-e"
  appendShellArgs(argv, shExe, shArgs)
  argv

proc buildShellCommand(cmd, shExe: string; hold = false):
    tuple[fullCmd: string, shArgs: seq[string]] =
  ## Run user's command in a group, and add a robust hold prompt when needed.
  ## Grouping prevents suffix binding to pipelines/conditionals.
  let suffix = (if hold: "" else: "; printf '\\n[Press Enter to close]\\n'; read -r _")
  let fullCmd = "{ " & cmd & " ; }" & suffix
  let shArgs = if shExe.endsWith("bash"): @["-lc", fullCmd] else: @["-c", fullCmd]
  (fullCmd, shArgs)

proc runCommand(cmd: string) =
  ## Run `cmd` in the user's terminal; fall back to /bin/sh if none.
  let bash = findExe("bash")
  let shExe = if bash.len > 0: bash else: "/bin/sh"

  var parts = tokenize(chooseTerminal()) # parser.tokenize on config.terminalExe/$TERMINAL
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
  ## Open *url* via xdg-open (no shell involved). Log failures for diagnosis.
  try:
    discard startProcess("/usr/bin/env", args = @["xdg-open", url], options = {poDaemon})
  except CatchableError as e:
    echo "openUrl failed: ", url, " (", e.name, "): ", e.msg

# ── Small searches: ~/.config helper ────────────────────────────────────
proc shortenPath(p: string; maxLen = 80): string =
  ## Replace $HOME with ~, and ellipsize the middle if too long.
  var s = p
  let home = getHomeDir()
  if s.startsWith(home & "/"): s = "~" & s[home.len .. ^1]
  if s.len <= maxLen: return s
  let keep = maxLen div 2 - 2
  if keep <= 0: return s
  result = s[0 ..< keep] & "…" & s[s.len - keep .. ^1]

proc scanFilesFast*(query: string): seq[string] =
  ## Fast file search in order:
  ##  1) `fd` (fast, respects .gitignore)
  ##  2) `locate -i` (DB backed, may be stale)
  ##  3) bounded walk under $HOME (slowest)
  let home  = getHomeDir()
  let ql    = query.toLowerAscii
  let limit = SearchFdCap

  try:
    # --- Prefer `fd` ----------------------------------------------------
    let fdExe = findExe("fd")
    if fdExe.len > 0:
      let args = @[
        "-i", "--type", "f", "--absolute-path",
        "--max-results", $limit, query, home
      ]
      let p = startProcess(fdExe, args = args, options = {poUsePath, poStdErrToStdOut})
      defer: close(p)
      let output = p.outputStream.readAll()
      for line in output.splitLines():
        if line.len > 0: result.add(line)
      return

    # --- Fallback: `locate -i` -----------------------------------------
    let locExe = findExe("locate")
    if locExe.len > 0:
      let p = startProcess(locExe, args = @["-i", "-l", $limit, query],
                           options = {poUsePath, poStdErrToStdOut})
      defer: close(p)
      let output = p.outputStream.readAll()
      for line in output.splitLines():
        if line.len > 0: result.add(line)
      return

    # --- Final fallback: bounded walk under $HOME -----------------------
    var count = 0
    for path in walkDirRec(home, yieldFilter = {pcFile}):
      if path.toLowerAscii.contains(ql):
        result.add(path)
        inc count
        if count >= limit: break

  except CatchableError as e:
    echo "scanFilesFast warning: ", e.name, ": ", e.msg

proc scanConfigFiles*(query: string): seq[DesktopApp] =
  ## Return entries from ~/.config matching `query` (case-insensitive).
  let base = getHomeDir() / ".config"
  let ql   = query.toLowerAscii
  for path in walkDirRec(base, yieldFilter = {pcFile}):
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
  let fallbackMatch = if baseMatchFgColorHex.len > 0:
    baseMatchFgColorHex
  else:
    cfg.matchFgColorHex
  for i, th in themeList:
    if th.name.toLowerAscii == name.toLowerAscii:
      cfg.bgColorHex = th.bgColorHex
      cfg.fgColorHex = th.fgColorHex
      cfg.highlightBgColorHex = th.highlightBgColorHex
      cfg.highlightFgColorHex = th.highlightFgColorHex
      cfg.borderColorHex = th.borderColorHex
      if th.matchFgColorHex.len > 0:
        cfg.matchFgColorHex = th.matchFgColorHex
      else:
        cfg.matchFgColorHex = fallbackMatch
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
        inTheme = false
        break
      if l.startsWith("last_chosen"):
        lines[i] = "last_chosen = \"" & config.themeName & "\""
        updated = true
        inTheme = false
        break
  if inTheme and not updated:
    lines.add("last_chosen = \"" & config.themeName & "\"")
    updated = true
  if not themeSectionFound:
    lines.add("")
    lines.add("[theme]")
    lines.add("last_chosen = \"" & config.themeName & "\"")
    updated = true
  if updated:
    writeFile(cfgPath, lines.join("\n"))

proc cycleTheme*(cfg: var Config) =
  ## Cycle to the next theme in `themeList` and persist the choice.
  if themeList.len == 0: return
  currentThemeIndex = (currentThemeIndex + 1) mod themeList.len
  let th = themeList[currentThemeIndex]
  applyThemeAndColors(cfg, th.name)
  saveLastTheme(getHomeDir() / ".config" / "nlauncher" / "nlauncher.toml")

# ── Applications discovery (.desktop) ───────────────────────────────────
proc loadApplications() =
  ## Scan .desktop files with caching to ~/.cache/nlauncher/apps.json.
  let usrDir   = "/usr/share/applications"
  let locDir   = getHomeDir() / ".local/share/applications"
  let cacheDir = getHomeDir() / ".cache" / "nlauncher"
  let cacheFile = cacheDir / "apps.json"

  let usrM = if dirExists(usrDir): times.toUnix(getLastModificationTime(usrDir)) else: 0'i64
  let locM = if dirExists(locDir): times.toUnix(getLastModificationTime(locDir)) else: 0'i64

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
        if isSome(opt):
          let app = get(opt)
          let key = getBaseExec(app.exec)
          if not dedup.hasKey(key) or (app.hasIcon and not dedup[key].hasIcon):
            dedup[key] = app

    allApps = dedup.values.toSeq
    allApps.sort(proc(a, b: DesktopApp): int = cmpIgnoreCase(a.name, b.name))
    filteredApps = allApps
    try:
      createDir(cacheDir)
      writeFile(cacheFile, pretty(%CacheData(usrMtime: usrM, localMtime: locM, apps: allApps)))
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
  if tbl.hasKey("window"):
    try:
      let w = tbl["window"].getTable()
      config.winWidth = w.getOrDefault("width").getInt(config.winWidth)
      config.maxVisibleItems = w.getOrDefault("max_visible_items").getInt(config.maxVisibleItems)
      config.centerWindow = w.getOrDefault("center").getBool(config.centerWindow)
      config.positionX = w.getOrDefault("position_x").getInt(config.positionX)
      config.positionY = w.getOrDefault("position_y").getInt(config.positionY)
      config.verticalAlign = w.getOrDefault("vertical_align").getStr(config.verticalAlign)
    except CatchableError:
      echo "nLauncher warning: ignoring invalid [window] section in ", cfgPath

  # font
  if tbl.hasKey("font"):
    try:
      let f = tbl["font"].getTable()
      config.fontName = f.getOrDefault("fontname").getStr(config.fontName)
    except CatchableError:
      echo "nLauncher warning: ignoring invalid [font] section in ", cfgPath

  # input
  if tbl.hasKey("input"):
    try:
      let inp = tbl["input"].getTable()
      config.prompt = inp.getOrDefault("prompt").getStr(config.prompt)
      config.cursor = inp.getOrDefault("cursor").getStr(config.cursor)
    except CatchableError:
      echo "nLauncher warning: ignoring invalid [input] section in ", cfgPath

  # terminal
  if tbl.hasKey("terminal"):
    try:
      let term = tbl["terminal"].getTable()
      config.terminalExe = term.getOrDefault("program").getStr(config.terminalExe)
    except CatchableError:
      echo "nLauncher warning: ignoring invalid [terminal] section in ", cfgPath

  # border
  if tbl.hasKey("border"):
    try:
      let b = tbl["border"].getTable()
      config.borderWidth = b.getOrDefault("width").getInt(config.borderWidth)
    except CatchableError:
      echo "nLauncher warning: ignoring invalid [border] section in ", cfgPath

  # themes
  themeList = @[]
  if tbl.hasKey("themes"):
    try:
      for thVal in tbl["themes"].getElems():
        let th = thVal.getTable()
        themeList.add Theme(
          name: th.getOrDefault("name").getStr(""),
          bgColorHex: th.getOrDefault("bgColorHex").getStr(""),
          fgColorHex: th.getOrDefault("fgColorHex").getStr(""),
          highlightBgColorHex: th.getOrDefault("highlightBgColorHex").getStr(""),
          highlightFgColorHex: th.getOrDefault("highlightFgColorHex").getStr(""),
          borderColorHex: th.getOrDefault("borderColorHex").getStr(""),
          matchFgColorHex: th.getOrDefault("matchFgColorHex").getStr("")
        )
    except CatchableError:
      echo "nLauncher warning: ignoring invalid [[themes]] entries in ", cfgPath

  # last_chosen (case-insensitive match; fallback to first theme)
  var lastName = ""
  if tbl.hasKey("theme"):
    try:
      let themeTbl = tbl["theme"].getTable()
      lastName = themeTbl.getOrDefault("last_chosen").getStr("")
    except CatchableError:
      echo "nLauncher warning: ignoring invalid [theme] section in ", cfgPath
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
  if baseMatchFgColorHex.len == 0:
    baseMatchFgColorHex = config.matchFgColorHex
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
      rest = ""; return true
    if input.len > n:
      if input[n] == ' ':
        rest = input[n+1 .. ^1].strip(); return true
      rest = input[n .. ^1].strip(); return true
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
      if qi == lq.len: return
  result.setLen(0)

proc subseqSpans(q, t: string): seq[(int, int)] =
  ## Convert positions to 1-char spans for highlighting.
  for p in subseqPositions(q, t): result.add (p, 1)

proc isWordBoundary(lt: string; idx: int): bool =
  ## Basic token boundary check for nicer scoring.
  if idx <= 0: return true
  let c = lt[idx-1]
  c == ' ' or c == '-' or c == '_' or c == '.' or c == '/'

proc scoreMatch(q, t, fullPath, home: string): int =
  ## Heuristic score for matching q against t (higher is better).
  ## Typo-friendly: 1 edit (ins/del/sub) or one adjacent transposition.
  if q.len == 0: return -1_000_000
  let lq = q.toLowerAscii
  let lt = t.toLowerAscii
  let pos = lt.find(lq)

  # fast helpers (no alloc)
  proc withinOneEdit(a, b: string): bool =
    let m = a.len; let n = b.len
    if abs(m - n) > 1: return false
    var i = 0; var j = 0; var edits = 0
    while i < m and j < n:
      if a[i] == b[j]: inc i; inc j
      else:
        inc edits; if edits > 1: return false
        if m == n: inc i; inc j
        elif m < n: inc j
        else: inc i
    edits += (m - i) + (n - j)
    edits <= 1

  proc withinOneTransposition(a, b: string): bool =
    if a.len != b.len or a.len < 2: return false
    var k = 0
    while k < a.len and a[k] == b[k]: inc k
    if k >= a.len - 1: return false
    if not (a[k] == b[k+1] and a[k+1] == b[k]): return false
    let tailStart = k + 2
    #if tailStart < a.len: a[tailStart .. ^1] == b[tailStart .. ^1] else: true
    result = if tailStart < a.len:
      a[tailStart .. ^1] == b[tailStart .. ^1]
    else:
      true

  var s = -1_000_000
  if pos >= 0:
    s = 1000
    if pos == 0: s += 200
    if isWordBoundary(lt, pos): s += 80
    s += max(0, 60 - (t.len - q.len))

  if t == q: s += 9000
  elif lt == lq: s += 8600
  elif lt.startsWith(lq): s += 8200
  elif pos >= 0: s += 7800
  else:
    var typoHit = false
    if lq.len >= 2:
      let sizes = [max(1, lq.len - 1), lq.len, lq.len + 1]
      for L in sizes:
        if L > lt.len: continue
        var start = 0
        let maxStart = lt.len - L
        while start <= maxStart:
          let seg = lt[start ..< start + L]
          if withinOneEdit(lq, seg) or withinOneTransposition(lq, seg):
            typoHit = true
            var base = 7700
            if start == 0: base = 7950
            s = max(s, base - min(120, start))
            break
          inc start
        if typoHit: break
    if not typoHit and lq.len >= 2:
      if withinOneEdit(lq, lt) or withinOneTransposition(lq, lt):
        s = max(s, 7600)

  if fullPath.startsWith(home & "/"):
    if lt == lq: s += 600
    elif lt.startsWith(lq): s += 400
  s

# ── Web shortcuts ───────────────────────────────────────────────────────
type WebSpec = tuple[prefix, label, base: string; kind: ActionKind]
const webSpecs: array[3, WebSpec] = [
  ("y:", "Search YouTube: ", "https://www.youtube.com/results?search_query=", akYouTube),
  ("g:", "Search Google: ", "https://www.google.com/search?q=", akGoogle),
  ("w:", "Search Wiki: ", "https://en.wikipedia.org/wiki/Special:Search?search=", akWiki)
]

type CmdKind = enum
  ## Recognised input prefixes.
  ckNone,        # no special prefix
  ckTheme,       # `t:`
  ckConfig,      # `c:`
  ckSearch,      # `s:` fast file search
  ckWeb,         # `y:`, `g:`, `w:`
  ckRun          # raw `/` command

proc parseCommand(inputText: string): (CmdKind, string, int) =
  ## Parse *inputText* and return the command kind, remainder, and web spec index.
  var rest: string
  if takePrefix(inputText, "c:", rest): return (ckConfig, rest, -1)
  if takePrefix(inputText, "t:", rest): return (ckTheme, rest, -1)
  if takePrefix(inputText, "s:", rest): return (ckSearch, rest, -1)
  for i, spec in webSpecs:
    if takePrefix(inputText, spec.prefix, rest): return (ckWeb, rest, i)
  if not inputText.startsWith("/"): return (ckNone, inputText, -1)
  if takePrefix(inputText, "/t", rest): return (ckTheme, rest, -1) # legacy alias
  discard takePrefix(inputText, "/", rest)
  (ckRun, rest.strip(), -1)

proc visibleQuery(inputText: string): string =
  ## Return the user's query sans command prefix so highlight works.
  let (_, rest, _) = parseCommand(inputText)
  rest

# ── Build actions & mirror to filteredApps ─────────────────────────────
proc buildActions() =
  ## Populate `actions` based on `inputText`; mirror to GUI lists/spans.
  actions.setLen(0)

  let (cmd, rest, webIdx) = parseCommand(inputText)
  var handled = true

  case cmd
  of ckTheme:
    let ql = rest.toLowerAscii
    for th in themeList:
      if ql.len == 0 or th.name.toLowerAscii.contains(ql):
        actions.add Action(kind: akTheme, label: th.name, exec: th.name)

  of ckConfig:
    for a in scanConfigFiles(rest):
      actions.add Action(kind: akConfig, label: a.name, exec: a.exec)

  of ckWeb:
    let spec = webSpecs[webIdx]
    actions.add Action(kind: spec.kind,
                       label: spec.label & rest,
                       exec: spec.base & encodeUrl(rest))

  of ckSearch:
    # Debounce heavy file scans while user is typing quickly.
    let sinceEdit = gui.nowMs() - lastInputChangeMs
    if rest.len < 2 or sinceEdit < SearchDebounceMs:
      actions.add Action(kind: akConfig, label: "Searching…", exec: "")
      handled = true
    else:
      gui.notifyStatus("Searching…", 1200)

      let restLower = rest.toLowerAscii

      # Reuse previous scan results if user is narrowing the query (prefix grow).
      var paths: seq[string]
      if lastSearchQuery.len > 0 and rest.len >= lastSearchQuery.len and
         rest.startsWith(lastSearchQuery) and lastSearchResults.len > 0:
        for p in lastSearchResults:
          if p.toLowerAscii.contains(restLower):
            paths.add p
      else:
        paths = scanFilesFast(rest)

      lastSearchQuery = rest
      lastSearchResults = paths

      let maxScore = min(paths.len, SearchShowCap)

      proc pathDepth(s: string): int =
        var d = 0
        for ch in s:
          if ch == '/': inc d
        d

      let home = getHomeDir()
      var top = initHeapQueue[(int, string)]()
      let limit = config.maxVisibleItems
      let ql = restLower

      for idx in 0 ..< maxScore:
        let p = paths[idx]
        let name = p.extractFilename
        var s = scoreMatch(rest, name, p, home)

        # Prefer exact/prefix basename matches heavily
        let nl = name.toLowerAscii
        if nl == ql: s += 12_000
        elif nl.startsWith(ql): s += 4_000

        # Prefer items under $HOME; penalize outside and very deep paths
        if p.startsWith(home & "/"):
          s += 800
          let dir = p[0 ..< max(0, p.len - name.len)]
          let relDepth = max(0, pathDepth(dir) - pathDepth(home))
          s -= min(relDepth, 10) * 200
          if dir == home or dir == (home & "/"):
            s += 5_000
            if name.len > 0 and name[0] == '.': s += 4_000
        else:
          s -= 2_000

        if s > -1_000_000:
          push(top, (s, p))
          if top.len > max(limit, 200): discard pop(top)

      var ranked: seq[(int, string)] = @[]
      while top.len > 0: ranked.add pop(top)
      ranked.sort(proc(a, b: (int, string)): int = cmp(b[0], a[0]))

      let showCap = max(limit, min(40, SearchShowCap))  # draw a fuller slice than visible
      for i, it in ranked:
        if i >= showCap: break
        let p = it[1]
        let name = p.extractFilename
        var dir = p[0 ..< max(0, p.len - name.len)]
        while dir.len > 0 and dir[^1] == '/': dir.setLen(dir.len - 1)
        let pretty = name & " — " & shortenPath(dir)
        actions.add Action(kind: akFile, label: pretty, exec: p)

  of ckRun:
    if rest.len > 0:
      actions.add Action(kind: akRun, label: "Run: " & rest, exec: rest)
    else:
      handled = false

  of ckNone:
    handled = false

  # Default view — app list (MRU first, then fuzzy)
  if not handled:
    if rest.len == 0:
      var index = initTable[string, DesktopApp](allApps.len * 2)
      for app in allApps: index[app.name] = app

      var seen = initHashSet[string]()
      for name in recentApps:
        if index.hasKey(name):
          let app = index[name]
          actions.add Action(kind: akApp, label: app.name, exec: app.exec, appData: app)
          seen.incl name

      for app in allApps:
        if not seen.contains(app.name):
          actions.add Action(kind: akApp, label: app.name, exec: app.exec, appData: app)

    else:
      var top = initHeapQueue[(int, int)]()
      let limit = config.maxVisibleItems
      for i, app in allApps:
        let s = scoreMatch(rest, app.name, app.name, "")
        if s > -1_000_000:
          push(top, (s + recentBoost(app.name), i))
          if top.len > limit: discard pop(top)
      var ranked: seq[(int, int)] = @[]
      while top.len > 0: ranked.add pop(top)
      ranked.sort(proc(a, b: (int, int)): int =
        result = cmp(b[0], a[0])
        if result == 0: result = cmpIgnoreCase(allApps[a[1]].name, allApps[b[1]].name)
      )
      actions.setLen(0)
      for it in ranked:
        let app = allApps[it[1]]
        actions.add Action(kind: akApp, label: app.name, exec: app.exec, appData: app)

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
      of akApp, akConfig, akTheme, akFile:
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
  of akFile:
    if not openPathWithDefault(a.exec):
      discard startProcess("/usr/bin/env", args = @["xdg-open", a.exec], options = {poDaemon})
  of akApp:
    # safer: strip .desktop field codes before launching
    let sanitized = parser.stripFieldCodes(a.exec).strip()
    discard startProcess("/bin/sh", args = ["-c", sanitized], options = {poDaemon})
    let ri = recentApps.find(a.label)
    if ri >= 0: recentApps.delete(ri)
    recentApps.insert(a.label, 0)
    if recentApps.len > maxRecent: recentApps.setLen(maxRecent)
    saveRecent()
  of akTheme:
    ## Apply and persist, but DO NOT reset selection or exit.
    applyThemeAndColors(config, a.exec)
    saveLastTheme(getHomeDir() / ".config" / "nlauncher" / "nlauncher.toml")
    exitAfter = false
  if exitAfter: shouldExit = true

# ── Main loop ───────────────────────────────────────────────────────────
proc main() =
  benchMode = "--bench" in commandLineParams()

  timeIt "Init Config:": initLauncherConfig()
  timeIt "Load Applications:": loadApplications()
  timeIt "Load Recent Apps:": loadRecent()
  timeIt "Build Actions:": buildActions()

  initGui()

  # Theme parsing must happen after initGui opens the display but before the
  # first redraw so Xft colours resolve correctly.
  timeIt "updateParsedColors:": updateParsedColors(config)
  timeIt "updateGuiColors:": gui.updateGuiColors()
  timeIt "Benchmark(Redraw Frame):": gui.redrawWindow()

  if benchMode: quit 0

  while not shouldExit:
    if XPending(display) == 0:
      # Debounce wake-up: if we're in s: search, rebuild after idle
      let (cmd, rest, _) = parseCommand(inputText)
      if cmd == ckSearch:
        let sinceEdit = gui.nowMs() - lastInputChangeMs
        if rest.len >= 2 and sinceEdit >= SearchDebounceMs and
           lastSearchBuildMs < lastInputChangeMs:
          lastSearchBuildMs = gui.nowMs()
          buildActions()
          gui.redrawWindow()
          continue
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
        ## Backspace: remove last char. Also map Left→Backspace for quick fix.
        if inputText.len > 0:
          inputText.setLen(inputText.len - 1)
          lastInputChangeMs = gui.nowMs()
          buildActions()

      of XK_Right:
        discard # no mid-string editing yet

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
        if filteredApps.len > 0:
          let step = max(1, config.maxVisibleItems)
          selectedIndex = max(0, selectedIndex - step)
          viewOffset = max(0, viewOffset - step)

      of XK_Page_Down:
        if filteredApps.len > 0:
          let step = max(1, config.maxVisibleItems)
          selectedIndex = min(filteredApps.len - 1, selectedIndex + step)
          let bottom = viewOffset + config.maxVisibleItems - 1
          if selectedIndex > bottom:
            viewOffset = min(selectedIndex, filteredApps.len - 1) - (config.maxVisibleItems - 1)
            if viewOffset < 0: viewOffset = 0

      of XK_Home:
        if filteredApps.len > 0:
          selectedIndex = 0
          viewOffset = 0

      of XK_End:
        if filteredApps.len > 0:
          selectedIndex = filteredApps.len - 1
          viewOffset = max(0, filteredApps.len - config.maxVisibleItems)

      of XK_F5:
        cycleTheme(config)

      else:
        if buf[0] != '\0' and buf[0] >= ' ':
          inputText.add(buf[0])
          lastInputChangeMs = gui.nowMs()
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
