## parser.nim — helpers for reading `.desktop` files
## MIT; see LICENSE for details.
##
## Public API:
##   • tokenize(cmd: string): seq[string]
##   • getBaseExec(exec: string): string
##   • getBestValue(entries, baseKey: string): string
##   • parseDesktopFile(path: string): Option[DesktopApp]
##
## Notes:
##   - We intentionally implement a *shell-ish* tokenizer (good enough for Exec=).
##   - Exec wrappers handled: env VAR=..., sh|bash|zsh -c "...", flatpak|snap run,
##     sudo/pkexec. The goal is a stable "base exec" key for deduplication.
##   - Locale resolution follows .desktop rules: key[lang_COUNTRY] → key[lang] → any variant.

import std/[os, strutils, streams, tables, options]
import state # DesktopApp

# ── Internal helpers ────────────────────────────────────────────────────

proc stripFieldCodes(s: string): string =
  ## Remove .desktop "field codes" from Exec lines (e.g. %f, %F, %u, %U, %i, %c, %k).
  ## We keep '%%' as a literal '%' (the spec’s escape), everything else `%<alpha>` is dropped.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '%' and i+1 < s.len:
      let n = s[i+1]
      if n == '%':
        result.add('%'); inc i, 2 # '%%' → '%'
        continue
      if n.isAlphaAscii:
        inc i, 2 # drop %X
        continue
    result.add s[i]
    inc i

proc tokenize*(cmd: string): seq[string] =
  ## Shell-ish tokenizer for Exec= lines.
  ## Handles simple quotes, backslash escapes inside double-quotes,
  ## and whitespace splitting. Not a full shell parser.
  var cur = newStringOfCap(32)
  var i = 0
  var inQuote = '\0'
  while i < cmd.len:
    let c = cmd[i]
    if inQuote == '\0':
      case c
      of ' ', '\t':
        if cur.len > 0:
          result.add cur
          cur.setLen(0)
      of '"', '\'':
        inQuote = c
      of '\\':
        if i+1 < cmd.len:
          cur.add cmd[i+1]
          inc i
      else:
        cur.add c
    else:
      if c == inQuote:
        inQuote = '\0'
      elif c == '\\' and inQuote == '"' and i+1 < cmd.len:
        cur.add cmd[i+1]
        inc i
      else:
        cur.add c
    inc i
  if cur.len > 0:
    result.add cur

proc isEnvAssign(tok: string): bool =
  ## True if token is an environment assignment (e.g., FOO=bar).
  let eq = tok.find('=')
  eq > 0 and tok[0..eq-1].allCharsInSet({'A'..'Z', 'a'..'z', '0'..'9', '_'})

proc containsIgnoreCase(a: openArray[string], needle: string): bool =
  ## Case-insensitive membership test for small arrays.
  let n = needle.toLowerAscii
  for x in a:
    if x.toLowerAscii == n:
      return true
  false

# ── Exec-line utilities ─────────────────────────────────────────────────

proc getBaseExec*(exec: string): string =
  ## Strip arguments/placeholders from Exec= and return a de-dup identifier.
  ## Examples:
  ##   "/usr/bin/kitty --single-instance"      → "kitty"
  ##   "code %F"                                → "code"
  ##   "env FOO=1 VAR=2 /opt/app/bin/foo %U"    → "foo"
  ##   "flatpak run com.app.Name"               → "com.app.Name"
  ##   "snap run app"                           → "app"
  ##   "sh -c 'prog --opt'"                     → "prog"
  let cleaned = stripFieldCodes(exec).strip()
  var toks = tokenize(cleaned)
  if toks.len == 0:
    return ""

  var idx = 0

  # env VAR=... wrapper
  if toks[0] == "env":
    idx = 1
    while idx < toks.len and isEnvAssign(toks[idx]):
      inc idx
    if idx >= toks.len:
      return "env"

  # sh|bash|zsh -c "…"
  if idx < toks.len and (toks[idx] in ["sh", "bash", "zsh"]) and idx+2 <= toks.len:
    var j = idx + 1
    while j < toks.len and toks[j] != "-c":
      inc j
    if j < toks.len and j+1 < toks.len:
      return getBaseExec(toks[j+1])

  # flatpak/snap run <app-id>
  if idx+2 < toks.len and toks[idx] == "flatpak" and toks[idx+1] == "run":
    return toks[idx+2].extractFilename()
  if idx+2 < toks.len and toks[idx] == "snap" and toks[idx+1] == "run":
    return toks[idx+2].extractFilename()

  # sudo/pkexec wrappers
  if idx < toks.len and (toks[idx] == "sudo" or toks[idx] == "pkexec"):
    inc idx
    if idx >= toks.len:
      return "sudo"
    return toks[idx].extractFilename()

  # default: first non-wrapper token’s basename
  toks[idx].extractFilename()

# ── Locale helpers ──────────────────────────────────────────────────────

proc localeChain(): seq[string] =
  ## Build a locale preference chain like: "en_AU", "en", then fallbacks.
  let envs = [getEnv("LC_ALL"), getEnv("LC_MESSAGES"), getEnv("LANG")]
  var base = ""
  for e in envs:
    if e.len > 0:
      base = e
      break
  if base.len > 0:
    var s = base
    let dot = s.find('.'); if dot >= 0: s = s[0 ..< dot]
    let at  = s.find('@'); if at  >= 0: s = s[0 ..< at]
    result.add s
    let us = s.find('_')
    if us >= 0:
      result.add s[0 ..< us]           # language only (e.g. "en")
    elif s.len >= 2:
      result.add s[0 ..< 2]
  # Always finish with plain English fallback, once.
  if not result.containsIgnoreCase("en"):
    result.add "en"

proc getBestValue*(entries: Table[string, string], baseKey: string): string =
  ## Return the most specific value for *baseKey* following .desktop rules.
  ## Order: exact key → key[lang_COUNTRY] → key[lang] → first key[anything] → "".
  if entries.hasKey(baseKey):
    return entries[baseKey]
  let prefs = localeChain()
  for loc in prefs:
    let k = baseKey & "[" & loc & "]"
    if entries.hasKey(k):
      return entries[k]
  for key, val in entries:
    if key.len > baseKey.len+1 and key.startsWith(baseKey & "["):
      return val
  ""

# ── .desktop parser ─────────────────────────────────────────────────────

proc parseDesktopFile*(path: string): Option[DesktopApp] =
  ## Parse *path* and return `some(DesktopApp)` if launchable; otherwise `none`.
  ## Criteria:
  ##   • has Name & Exec
  ##   • NoDisplay=false
  ##   • Terminal=false
  ##   • filters out exact "Settings" / "System" categories
  let fs = newFileStream(path, fmRead)
  if fs.isNil:
    return none(DesktopApp)
  defer: fs.close()

  var inDesktopEntry = false
  var kv = initTable[string, string]()

  for raw in fs.lines:
    let line = raw.strip()
    if line.len == 0 or line.startsWith('#'):
      continue
    if line.startsWith('[') and line.endsWith(']'):
      inDesktopEntry = (line == "[Desktop Entry]")
      continue
    if inDesktopEntry and '=' in line:
      let parts = line.split('=', 1)
      if parts.len == 2:
        kv[parts[0].strip()] = parts[1].strip()

  let name = getBestValue(kv, "Name")
  let exec = getBestValue(kv, "Exec")
  let categories = kv.getOrDefault("Categories", "")
  let icon = kv.getOrDefault("Icon", "")
  let noDisplay = kv.getOrDefault("NoDisplay", "false").toLowerAscii() == "true"
  let terminalApp = kv.getOrDefault("Terminal", "false").toLowerAscii() == "true"

  # Category filter: exclude Settings/System (exact tokens, case-insensitive)
  var catHit = false
  for tok in categories.split(';'):
    let t = tok.strip()
    if t.len == 0: continue
    if t.cmpIgnoreCase("Settings") == 0 or t.cmpIgnoreCase("System") == 0:
      catHit = true
      break

  let launchable =
    name.len > 0 and exec.len > 0 and
    not noDisplay and not terminalApp and not catHit

  if launchable:
    some(DesktopApp(name: name, exec: exec, hasIcon: icon.len > 0))
  else:
    none(DesktopApp)
