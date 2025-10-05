## nimlaunch.nim — main program
## MIT; see LICENSE for details.

# ── Imports ─────────────────────────────────────────────────────────────
import std/[os, osproc, strutils, options, tables, sequtils, json, uri, sets,
            algorithm, times, heapqueue, streams, exitprocs]
when defined(posix):
  import posix
import parsetoml as toml
import x11/[xlib, xutil, x, keysym]
import ./[state, parser, gui, utils]
when defined(posix):
  when not declared(flock):
    proc flock(fd: cint; operation: cint): cint {.importc, header: "<sys/file.h>".}

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
  CacheFormatVersion = 3

var
  lockFilePath = ""
when defined(posix):
  var lockFd: cint = -1

# ── Single-instance helpers ────────────────────────────────────────────
when defined(posix):
  const
    LOCK_EX = 2.cint
    LOCK_NB = 4.cint
    LOCK_UN = 8.cint

  proc releaseSingleInstanceLock() =
    if lockFd >= 0:
      discard flock(lockFd, LOCK_UN)
      discard close(lockFd)
      lockFd = -1
    if lockFilePath.len > 0 and fileExists(lockFilePath):
      try:
        removeFile(lockFilePath)
      except CatchableError:
        discard

  proc ensureSingleInstance(): bool =
    ## Obtain an exclusive advisory lock; return false if another instance owns it.
    let cacheDir = getHomeDir() / ".cache" / "nimlaunch"
    try:
      createDir(cacheDir)
    except CatchableError:
      discard
    lockFilePath = cacheDir / "nimlaunch.lock"

    let fd = open(lockFilePath.cstring, O_RDWR or O_CREAT, 0o664)
    if fd < 0:
      echo "NimLaunch warning: unable to open lock file at ", lockFilePath
      return true

    if flock(fd, LOCK_EX or LOCK_NB) != 0:
      discard close(fd)
      return false

    discard ftruncate(fd, 0)
    discard lseek(fd, 0, 0)
    let pidStr = $getCurrentProcessId() & "\n"
    discard write(fd, pidStr.cstring, pidStr.len.cint)

    lockFd = fd
    addExitProc(releaseSingleInstanceLock)
    true
else:
  proc releaseSingleInstanceLock() =
    if lockFilePath.len > 0 and fileExists(lockFilePath):
      try:
        removeFile(lockFilePath)
      except CatchableError:
        discard

  proc ensureSingleInstance(): bool =
    ## Basic file sentinel fallback for non-POSIX targets.
    let cacheDir = getHomeDir() / ".cache" / "nimlaunch"
    try:
      createDir(cacheDir)
    except CatchableError:
      discard
    lockFilePath = cacheDir / "nimlaunch.lock"

    if fileExists(lockFilePath):
      return false

    try:
      writeFile(lockFilePath, $getCurrentProcessId())
      addExitProc(releaseSingleInstanceLock)
    except CatchableError:
      discard
    true

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
    discard startProcess(shExe, args = shArgs,
                         options = {poDaemon, poParentStreams})
    return

  let exe = parts[0]
  let exePath = findExe(exe)
  if exePath.len == 0:
    let (_, shArgs) = buildShellCommand(cmd, shExe)
    discard startProcess(shExe, args = shArgs,
                         options = {poDaemon, poParentStreams})
    return

  var termArgs = if parts.len > 1: parts[1..^1] else: @[]
  let base = exe.extractFilename()
  let hold = hasHoldFlagLocal(termArgs)
  let (_, shArgs) = buildShellCommand(cmd, shExe, hold)
  let argv = buildTerminalArgs(base, termArgs, shExe, shArgs)
  discard startProcess(exePath, args = argv,
                       options = {poDaemon, poParentStreams})

proc spawnShellCommand(cmd: string): bool =
  ## Execute *cmd* via /bin/sh in the background; return success.
  try:
    discard startProcess("/bin/sh", args = ["-c", cmd],
                         options = {poDaemon, poParentStreams})
    true
  except CatchableError as e:
    echo "spawnShellCommand failed: ", cmd, " (", e.name, "): ", e.msg
    false

proc openUrl(url: string) =
  ## Open *url* via xdg-open (no shell involved). Log failures for diagnosis.
  try:
    discard startProcess("/usr/bin/env", args = @["xdg-open", url],
                         options = {poDaemon, poParentStreams})
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
    ## --- Prefer `fd` ----------------------------------------------------
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

    ## --- Fallback: `locate -i` -----------------------------------------
    let locExe = findExe("locate")
    if locExe.len > 0:
      let p = startProcess(locExe, args = @["-i", "-l", $limit, query],
                           options = {poUsePath, poStdErrToStdOut})
      defer: close(p)
      let output = p.outputStream.readAll()
      for line in output.splitLines():
        if line.len > 0: result.add(line)
      return

    ## --- Final fallback: bounded walk under $HOME -----------------------
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
  try:
    for path in walkDirRec(base, yieldFilter = {pcFile}):
      let fn = path.extractFilename
      if fn.len > 0 and fn.toLowerAscii.contains(ql):
        result.add DesktopApp(
          name: fn,
          exec: "xdg-open " & shellQuote(path),
          hasIcon: false
        )
  except OSError:
    discard

# ── Prefix helpers ─────────────────────────────────────────────────────
proc normalizePrefix(prefix: string): string =
  ## Canonicalise user-configured prefixes by trimming colons/whitespace and
  ## lowercasing so parsing is resilient to variants like ":g", "g:" or ":G:".
  result = prefix.strip(chars = Whitespace + {':'}).toLowerAscii

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
  saveLastTheme(getHomeDir() / ".config" / "nimlaunch" / "nimlaunch.toml")

# ── Applications discovery (.desktop) ───────────────────────────────────
proc newestDesktopMtime(dir: string): int64 =
  ## Return the newest modification time among *.desktop files under *dir*.
  if not dirExists(dir): return 0
  var newest = 0'i64
  for path in walkFiles(dir / "*.desktop"):
    let m = times.toUnix(getLastModificationTime(path))
    if m > newest: newest = m
  newest

proc loadApplications() =
  ## Scan .desktop files with caching to ~/.cache/nimlaunch/apps.json.
  let usrDir   = "/usr/share/applications"
  let locDir   = getHomeDir() / ".local/share/applications"
  let flatpakUserDir = getHomeDir() / ".local/share/flatpak/exports/share/applications"
  let flatpakSystemDir = "/var/lib/flatpak/exports/share/applications"
  let cacheDir = getHomeDir() / ".cache" / "nimlaunch"
  let cacheFile = cacheDir / "apps.json"

  let usrM = newestDesktopMtime(usrDir)
  let locM = newestDesktopMtime(locDir)
  let flatpakUserM = newestDesktopMtime(flatpakUserDir)
  let flatpakSystemM = newestDesktopMtime(flatpakSystemDir)

  if fileExists(cacheFile):
    try:
      let node = parseJson(readFile(cacheFile))
      if node.kind == JObject and node.hasKey("formatVersion") and
         node["formatVersion"].getInt == CacheFormatVersion:
        let c = to(node, CacheData)
        if c.usrMtime == usrM and c.localMtime == locM and
           c.flatpakUserMtime == flatpakUserM and
           c.flatpakSystemMtime == flatpakSystemM:
          timeIt "Cache hit:":
            allApps = c.apps
            filteredApps = allApps
          return
      else:
        echo "Cache invalid — rescanning …"
    except:
      echo "Cache miss — rescanning …"

  timeIt "Full scan:":
    var dedup = initTable[string, DesktopApp]()
    for dir in @[flatpakUserDir, locDir, usrDir, flatpakSystemDir]:
      if not dirExists(dir): continue
      for path in walkFiles(dir / "*.desktop"):
        let opt = parseDesktopFile(path)
        if isSome(opt):
          let app = get(opt)
          let sanitizedExec = parser.stripFieldCodes(app.exec).strip()
          var key = sanitizedExec.toLowerAscii
          if key.len == 0:
            key = getBaseExec(app.exec).toLowerAscii
          if key.len == 0:
            key = app.name.toLowerAscii
          if not dedup.hasKey(key) or (app.hasIcon and not dedup[key].hasIcon):
            dedup[key] = app

    allApps = dedup.values.toSeq
    allApps.sort(proc(a, b: DesktopApp): int = cmpIgnoreCase(a.name, b.name))
    filteredApps = allApps
    try:
      createDir(cacheDir)
      writeFile(cacheFile, pretty(%CacheData(formatVersion: CacheFormatVersion,
                                             usrMtime: usrM,
                                             localMtime: locM,
                                             flatpakUserMtime: flatpakUserM,
                                             flatpakSystemMtime: flatpakSystemM,
                                             apps: allApps)))
    except:
      echo "Warning: cache not saved."

# ── Config helpers ───────────────────────────────────────────────────────
proc loadShortcutsSection(tbl: toml.TomlValueRef; cfgPath: string) =
  ## Populate `state.shortcuts` from `[[shortcuts]]` entries in *tbl*.
  shortcuts = @[]
  if not tbl.hasKey("shortcuts"): return

  try:
    for scVal in tbl["shortcuts"].getElems():
      let scTbl = scVal.getTable()
      let prefixRaw = scTbl.getOrDefault("prefix").getStr("")
      let prefix = normalizePrefix(prefixRaw)
      let base = scTbl.getOrDefault("base").getStr("").strip()
      if prefix.len == 0 or base.len == 0:
        continue

      let label = scTbl.getOrDefault("label").getStr("").strip(chars = {'\t', '\r', '\n'})
      let modeStr = scTbl.getOrDefault("mode").getStr("url").toLowerAscii

      var mode = smUrl
      case modeStr
      of "shell": mode = smShell
      of "file": mode = smFile
      else: discard

      shortcuts.add Shortcut(prefix: prefix, label: label, base: base, mode: mode)
  except CatchableError:
    echo "NimLaunch warning: ignoring invalid [[shortcuts]] entries in ", cfgPath

proc loadPowerSection(tbl: toml.TomlValueRef; cfgPath: string) =
  ## Populate power prefix and `state.powerActions` from *tbl*.
  powerActions = @[]

  if tbl.hasKey("power"):
    try:
      let p = tbl["power"].getTable()
      let rawPrefix = p.getOrDefault("prefix").getStr(config.powerPrefix)
      config.powerPrefix = normalizePrefix(rawPrefix)
    except CatchableError:
      echo "NimLaunch warning: ignoring invalid [power] section in ", cfgPath

  if not tbl.hasKey("power_actions"): return

  try:
    for paVal in tbl["power_actions"].getElems():
      let paTbl = paVal.getTable()
      let label = paTbl.getOrDefault("label").getStr("").strip()
      let command = paTbl.getOrDefault("command").getStr("").strip()
      if label.len == 0 or command.len == 0:
        continue

      var mode = pamSpawn
      let modeStr = paTbl.getOrDefault("mode").getStr("spawn").strip().toLowerAscii
      case modeStr
      of "terminal": mode = pamTerminal
      of "spawn", "shell": discard
      else: discard

      let stayOpen = paTbl.getOrDefault("stay_open").getBool(false)

      powerActions.add PowerAction(label: label,
                                   command: command,
                                   mode: mode,
                                   stayOpen: stayOpen)
  except CatchableError:
    echo "NimLaunch warning: ignoring invalid [[power_actions]] entries in ", cfgPath

# ── Load & apply config from TOML ───────────────────────────────────────
proc initLauncherConfig() =
  ## Initialize defaults, read TOML, apply last theme, compute geometry.
  config = Config() # zero-init

  ## In-code defaults
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
  config.powerPrefix = normalizePrefix("p:")
  config.vimMode = false

  ## Ensure TOML exists
  let cfgDir = getHomeDir() / ".config" / "nimlaunch"
  let cfgPath = cfgDir / "nimlaunch.toml"
  if not fileExists(cfgPath):
    createDir(cfgDir)
    writeFile(cfgPath, defaultToml)
    echo "Created default config at ", cfgPath

  ## Parse TOML
  let tbl = toml.parseFile(cfgPath)

  ## window
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
      echo "NimLaunch warning: ignoring invalid [window] section in ", cfgPath

  ## font
  if tbl.hasKey("font"):
    try:
      let f = tbl["font"].getTable()
      config.fontName = f.getOrDefault("fontname").getStr(config.fontName)
    except CatchableError:
      echo "NimLaunch warning: ignoring invalid [font] section in ", cfgPath

  ## input
  if tbl.hasKey("input"):
    try:
      let inp = tbl["input"].getTable()
      config.prompt = inp.getOrDefault("prompt").getStr(config.prompt)
      config.cursor = inp.getOrDefault("cursor").getStr(config.cursor)
      config.vimMode = inp.getOrDefault("vim_mode").getBool(config.vimMode)
    except CatchableError:
      echo "NimLaunch warning: ignoring invalid [input] section in ", cfgPath

  ## terminal
  if tbl.hasKey("terminal"):
    try:
      let term = tbl["terminal"].getTable()
      config.terminalExe = term.getOrDefault("program").getStr(config.terminalExe)
    except CatchableError:
      echo "NimLaunch warning: ignoring invalid [terminal] section in ", cfgPath

  ## border
  if tbl.hasKey("border"):
    try:
      let b = tbl["border"].getTable()
      config.borderWidth = b.getOrDefault("width").getInt(config.borderWidth)
    except CatchableError:
      echo "NimLaunch warning: ignoring invalid [border] section in ", cfgPath

  ## themes
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
      echo "NimLaunch warning: ignoring invalid [[themes]] entries in ", cfgPath

  loadShortcutsSection(tbl, cfgPath)
  loadPowerSection(tbl, cfgPath)

  ## last_chosen (case-insensitive match; fallback to first theme)
  var lastName = ""
  if tbl.hasKey("theme"):
    try:
      let themeTbl = tbl["theme"].getTable()
      lastName = themeTbl.getOrDefault("last_chosen").getStr("")
    except CatchableError:
      echo "NimLaunch warning: ignoring invalid [theme] section in ", cfgPath
  var pickedIndex = -1
  if lastName.len > 0:
    for i, th in themeList:
      if th.name.toLowerAscii == lastName.toLowerAscii:
        pickedIndex = i
        break
  if pickedIndex < 0:
    if themeList.len > 0: pickedIndex = 0
    else: quit("NimLaunch error: no themes defined in nimlaunch.toml")

  let chosen = themeList[pickedIndex].name
  config.themeName = chosen
  if baseMatchFgColorHex.len == 0:
    baseMatchFgColorHex = config.matchFgColorHex
  applyTheme(config, chosen)
  if chosen != lastName:
    saveLastTheme(cfgPath)

  ## derived geometry
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

  ## fast helpers (no alloc)
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

type CmdKind = enum
  ## Recognised input prefixes.
  ckNone,        # no special prefix
  ckTheme,       # `t:`
  ckConfig,      # `c:`
  ckSearch,      # `s:` fast file search
  ckPower,       # `p:` system/power actions
  ckShortcut,    # custom shortcuts (e.g. :g, :wiki)
  ckRun          # raw `r:` command

proc parseCommand(inputText: string): (CmdKind, string, int) =
  ## Parse *inputText* and return the command kind, remainder, and shortcut index.
  if inputText.len > 0 and inputText[0] == ':':
    var body = inputText[1 .. ^1]
    var rest = ""
    let sep = body.find({' ', '\t'})
    var keyword = body
    if sep >= 0:
      keyword = body[0 ..< sep]
      rest = body[sep + 1 .. ^1].strip()
    else:
      rest = ""
    let norm = normalizePrefix(keyword)
    case norm
    of "s": return (ckSearch, rest, -1)
    of "c": return (ckConfig, rest, -1)
    of "t": return (ckTheme, rest, -1)
    of "r": return (ckRun, rest, -1)
    else:
      if config.powerPrefix.len > 0 and norm == config.powerPrefix:
        return (ckPower, rest, -1)
      for i, sc in shortcuts:
        if norm == sc.prefix:
          return (ckShortcut, rest, i)
      return (ckNone, inputText, -1)

  var rest: string
  if takePrefix(inputText, "!", rest):
    return (ckRun, rest.strip(), -1)
  (ckNone, inputText, -1)

proc visibleQuery(inputText: string): string =
  ## Return the user's query sans command prefix so highlight works.
  let (_, rest, _) = parseCommand(inputText)
  rest

proc substituteQuery(pattern, value: string): string =
  ## Replace `{query}` placeholder or append value if absent.
  if pattern.contains("{query}"):
    result = pattern.replace("{query}", value)
  else:
    result = pattern & value

proc shortcutLabel(sc: Shortcut; query: string): string =
  ## Compose UI label for a shortcut result. Preserve user-provided spacing
  ## but inject a single space when the label doesn't already end with one.
  if sc.label.len == 0:
    return query

  if query.len == 0:
    return sc.label

  result = sc.label
  let last = sc.label[^1]
  if not last.isSpaceAscii():
    result.add ' '
  result.add query

proc shortcutExec(sc: Shortcut; query: string): string =
  ## Build the execution string for a shortcut before mode-specific handling.
  case sc.mode
  of smUrl:
    result = substituteQuery(sc.base, encodeUrl(query))
  of smShell:
    result = substituteQuery(sc.base, shellQuote(query))
  of smFile:
    result = substituteQuery(sc.base, query)

# ── Build actions & mirror to filteredApps ─────────────────────────────
proc buildActions() =
  ## Populate `actions` based on `inputText`; mirror to GUI lists/spans.
  actions.setLen(0)

  let (cmd, rest, shortcutIdx) = parseCommand(inputText)
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

  of ckShortcut:
    if shortcutIdx >= 0 and shortcutIdx < shortcuts.len:
      let sc = shortcuts[shortcutIdx]
      actions.add Action(kind: akShortcut,
                         label: shortcutLabel(sc, rest),
                         exec: shortcutExec(sc, rest),
                         shortcutMode: sc.mode)

  of ckPower:
    if powerActions.len == 0:
      actions.add Action(kind: akPlaceholder,
                         label: "No power actions configured",
                         exec: "")
    else:
      let ql = rest.strip().toLowerAscii
      var matched = 0
      for pa in powerActions:
        if ql.len == 0 or pa.label.toLowerAscii.contains(ql):
          actions.add Action(kind: akPower,
                             label: pa.label,
                             exec: pa.command,
                             powerMode: pa.mode,
                             stayOpen: pa.stayOpen)
          inc matched
      if matched == 0:
        actions.add Action(kind: akPlaceholder,
                           label: "No matches",
                           exec: "")

  of ckSearch:
    ## Debounce heavy file scans while user is typing quickly.
    let sinceEdit = gui.nowMs() - lastInputChangeMs
    if rest.len < 2 or sinceEdit < SearchDebounceMs:
      actions.add Action(kind: akPlaceholder, label: "Searching…", exec: "")
      handled = true
    else:
      gui.notifyStatus("Searching…", 1200)

      let restLower = rest.toLowerAscii

      ## Reuse previous scan results if user is narrowing the query (prefix grow).
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

        ## Prefer exact/prefix basename matches heavily
        let nl = name.toLowerAscii
        if nl == ql: s += 12_000
        elif nl.startsWith(ql): s += 4_000

        ## Prefer items under $HOME; penalize outside and very deep paths
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
      actions.add Action(kind: akPlaceholder,
                         label: "Run: enter a command",
                         exec: "")

  of ckNone:
    handled = false

  ## Default view — app list (MRU first, then fuzzy)
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

  ## Mirror to filteredApps + highlight spans
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
      of akApp, akConfig, akTheme, akFile, akShortcut, akPower, akPlaceholder:
        matchSpans.add subseqSpans(q, act.label)
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
  of akConfig:
    if not spawnShellCommand(a.exec):
      gui.notifyStatus("Failed: " & a.label, 1600)
      exitAfter = false
  of akFile:
    discard openPathWithFallback(a.exec)
  of akApp:
    ## safer: strip .desktop field codes before launching
    let sanitized = parser.stripFieldCodes(a.exec).strip()
    if spawnShellCommand(sanitized):
      let ri = recentApps.find(a.label)
      if ri >= 0: recentApps.delete(ri)
      recentApps.insert(a.label, 0)
      if recentApps.len > maxRecent: recentApps.setLen(maxRecent)
      saveRecent()
    else:
      gui.notifyStatus("Failed: " & a.label, 1600)
      exitAfter = false
  of akShortcut:
    case a.shortcutMode
    of smUrl:
      openUrl(a.exec)
    of smShell:
      runCommand(a.exec)
    of smFile:
      let expanded = a.exec.expandTilde()
      if not fileExists(expanded) and not dirExists(expanded):
        gui.notifyStatus("Not found: " & shortenPath(expanded, 50), 1600)
        exitAfter = false
      elif not openPathWithFallback(expanded):
        gui.notifyStatus("Failed to open: " & shortenPath(expanded, 50), 1600)
        exitAfter = false
  of akPower:
    var success = true
    case a.powerMode
    of pamSpawn:
      success = spawnShellCommand(a.exec)
    of pamTerminal:
      runCommand(a.exec)
    if not success:
      gui.notifyStatus("Failed: " & a.label, 1600)
      exitAfter = false
    elif a.stayOpen:
      exitAfter = false
  of akTheme:
    ## Apply and persist, but DO NOT reset selection or exit.
    applyThemeAndColors(config, a.exec)
    saveLastTheme(getHomeDir() / ".config" / "nimlaunch" / "nimlaunch.toml")
    exitAfter = false
  of akPlaceholder:
    exitAfter = false
  if exitAfter: shouldExit = true

# ── Input/navigation helpers ───────────────────────────────────────────
proc deleteLastInputChar() =
  if inputText.len > 0:
    inputText.setLen(inputText.len - 1)
    lastInputChangeMs = gui.nowMs()
    buildActions()

proc activateCurrentSelection() =
  if selectedIndex in 0..<actions.len:
    performAction(actions[selectedIndex])

proc moveSelectionBy(step: int) =
  if filteredApps.len == 0: return
  var newIndex = selectedIndex + step
  if newIndex < 0: newIndex = 0
  if newIndex > filteredApps.len - 1: newIndex = filteredApps.len - 1
  if newIndex == selectedIndex: return
  selectedIndex = newIndex
  if selectedIndex < viewOffset:
    viewOffset = selectedIndex
  elif selectedIndex >= viewOffset + config.maxVisibleItems:
    viewOffset = selectedIndex - config.maxVisibleItems + 1
    if viewOffset < 0: viewOffset = 0

proc jumpToTop() =
  if filteredApps.len == 0: return
  selectedIndex = 0
  viewOffset = 0

proc jumpToBottom() =
  if filteredApps.len == 0: return
  selectedIndex = filteredApps.len - 1
  let start = filteredApps.len - config.maxVisibleItems
  viewOffset = if start > 0: start else: 0

proc syncVimCommand() =
  inputText = vimCommandBuffer
  lastInputChangeMs = gui.nowMs()
  buildActions()

proc openVimCommand(initial: string = "") =
  if not vimCommandActive:
    vimSavedInput = inputText
    vimSavedSelectedIndex = selectedIndex
    vimSavedViewOffset = viewOffset
    vimCommandRestorePending = true
  vimCommandBuffer = initial
  vimCommandActive = true
  vimPendingG = false
  syncVimCommand()

proc closeVimCommand(restoreInput = false) =
  let savedInput = vimSavedInput
  let savedSelected = vimSavedSelectedIndex
  let savedOffset = vimSavedViewOffset
  vimCommandBuffer.setLen(0)
  vimCommandActive = false
  vimPendingG = false

  if restoreInput and vimCommandRestorePending:
    inputText = savedInput
    lastInputChangeMs = gui.nowMs()
    buildActions()

    if filteredApps.len > 0:
      let clampedSel = max(0, min(savedSelected, filteredApps.len - 1))
      let visibleRows = max(1, config.maxVisibleItems)
      let maxOffset = max(0, filteredApps.len - visibleRows)
      var newOffset = max(0, min(savedOffset, maxOffset))
      if clampedSel < newOffset:
        newOffset = clampedSel
      elif clampedSel >= newOffset + visibleRows:
        newOffset = max(0, clampedSel - visibleRows + 1)
      selectedIndex = clampedSel
      viewOffset = newOffset
    else:
      selectedIndex = 0
      viewOffset = 0

  vimSavedInput = ""
  vimSavedSelectedIndex = 0
  vimSavedViewOffset = 0
  vimCommandRestorePending = false



proc executeVimCommand() =
  let trimmed = vimCommandBuffer.strip()
  closeVimCommand()
  if trimmed.len == 0:
    return
  if trimmed == ":q":
    shouldExit = true
    return
  inputText = trimmed
  lastInputChangeMs = gui.nowMs()
  buildActions()

proc handleVimKey(ks: KeySym; ch: char; state: cuint): bool =
  if not config.vimMode:
    return false

  if vimCommandActive:
    case ks
    of XK_Return:
      executeVimCommand()
      return true
    of XK_BackSpace, XK_Delete:
      if vimCommandBuffer.len > 0:
        vimCommandBuffer.setLen(vimCommandBuffer.len - 1)
        syncVimCommand()
      else:
        closeVimCommand(restoreInput = true)
      return true
    of XK_h:
      if (state and ControlMask.cuint) != 0:
        if vimCommandBuffer.len > 0:
          vimCommandBuffer.setLen(vimCommandBuffer.len - 1)
          syncVimCommand()
        else:
          closeVimCommand(restoreInput = true)
        return true
    of XK_u:
      if (state and ControlMask.cuint) != 0:
        vimCommandBuffer.setLen(0)
        syncVimCommand()
        return true
    of XK_Escape:
      closeVimCommand(restoreInput = true)
      return true
    else:
      if ch != '\0' and ch >= ' ':
        vimCommandBuffer.add(ch)
        syncVimCommand()
      return true

  case ks
  of XK_slash:
    if vimCommandActive:
      vimCommandBuffer.add('/')
      syncVimCommand()
    else:
      openVimCommand("")
    return true
  of XK_colon:
    openVimCommand(":")
    return true
  of XK_exclam:
    openVimCommand("!")
    return true
  of XK_g, XKc_G:
    let shiftHeld = (ks == XKc_G) or (state and ShiftMask.cuint) != 0 or ch == 'G'
    if shiftHeld:
      vimPendingG = false
      jumpToBottom()
    elif vimPendingG:
      vimPendingG = false
      jumpToTop()
    else:
      vimPendingG = true
    return true
  of XK_Escape:
    shouldExit = true
    return true
  of XK_j:
    vimPendingG = false
    moveSelectionBy(1)
    return true
  of XK_k:
    vimPendingG = false
    moveSelectionBy(-1)
    return true
  of XK_h:
    vimPendingG = false
    deleteLastInputChar()
    return true
  of XK_l:
    vimPendingG = false
    activateCurrentSelection()
    return true
  else:
    if ch != '\0' and ch >= ' ':
      vimPendingG = false
      return true
    vimPendingG = false
    return false

# ── Main loop ───────────────────────────────────────────────────────────
proc main() =
  if not ensureSingleInstance():
    echo "NimLaunch is already running."
    quit 0
  benchMode = "--bench" in commandLineParams()

  timeIt "Init Config:": initLauncherConfig()
  timeIt "Load Applications:": loadApplications()
  timeIt "Load Recent Apps:": loadRecent()
  timeIt "Build Actions:": buildActions()

  vimPendingG = false
  vimCommandBuffer.setLen(0)
  vimCommandActive = false

  initGui()

  ## Theme parsing must happen after initGui opens the display but before the
  ## first redraw so Xft colours resolve correctly.
  timeIt "updateParsedColors:": updateParsedColors(config)
  timeIt "updateGuiColors:": gui.updateGuiColors()
  timeIt "Benchmark(Redraw Frame):": gui.redrawWindow()

  if benchMode: quit 0

  while not shouldExit:
    if XPending(display) == 0:
      ## Debounce wake-up: if we're in s: search, rebuild after idle
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
      let ch = buf[0]
      var handled = false
      if config.vimMode:
        handled = handleVimKey(ks, ch, ev.xkey.state)
      elif (ks == XK_u or ks == XK_U) and ((ev.xkey.state and ControlMask.cuint) != 0):
        inputText.setLen(0)
        lastInputChangeMs = gui.nowMs()
        buildActions()
        handled = true
      elif (ks == XK_h or ks == XK_H) and ((ev.xkey.state and ControlMask.cuint) != 0):
        deleteLastInputChar()
        handled = true
      if not handled:
        case ks
        of XK_Escape:
          shouldExit = true

        of XK_Return:
          activateCurrentSelection()

        of XK_BackSpace, XK_Left:
          deleteLastInputChar()

        of XK_Right:
          discard # no mid-string editing yet

        of XK_Up:
          moveSelectionBy(-1)

        of XK_Down:
          moveSelectionBy(1)

        of XK_Page_Up:
          if filteredApps.len > 0:
            moveSelectionBy(-max(1, config.maxVisibleItems))

        of XK_Page_Down:
          if filteredApps.len > 0:
            moveSelectionBy(max(1, config.maxVisibleItems))

        of XK_Home:
          jumpToTop()

        of XK_End:
          jumpToBottom()

        of XK_F5:
          cycleTheme(config)

        else:
          if ch != '\0' and ch >= ' ':
            inputText.add(ch)
            lastInputChangeMs = gui.nowMs()
            buildActions()

      if not shouldExit:
        gui.redrawWindow()

    of ButtonPress:
      shouldExit = true
    of FocusOut:
      let mode = ev.xfocus.mode
      if mode == NotifyGrab or mode == NotifyUngrab:
        discard
      elif seenMapNotify:
        seenMapNotify = false
      else:
        shouldExit = true
    else:
      discard

  discard XDestroyWindow(display, window)
  discard XCloseDisplay(display)

when isMainModule:
  main()
