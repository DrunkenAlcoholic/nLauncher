## parser.nim — helpers for reading `.desktop` files
## GNU GPL v3 (or later); see LICENSE.
##
## Public interface:
##   • getBaseExec(str): string
##   • getBestValue(tbl, key): string
##   • parseDesktopFile(path): Option[DesktopApp]
##
## No state is mutated in this module.  Errors fall back to `none(DesktopApp)`.

# ── Imports ─────────────────────────────────────────────────────────────
import std/[os, strutils, streams, tables, options]
import state               # DesktopApp

# ── Exec‑line utility ───────────────────────────────────────────────────
proc getBaseExec*(exec: string): string =
  ## Strip argument/placeholder parts from an Exec= line and return the bare
  ## executable filename (no directories).
  ##
  ## Examples:
  ##   "/usr/bin/kitty --single-instance" → "kitty"
  ##   "code %F"                         → "code"
  let clean = exec.split('%')[0].strip()
  clean.split(' ')[0].extractFilename()

# ── Key‑locale resolver ─────────────────────────────────────────────────
proc getBestValue*(entries: Table[string, string], baseKey: string): string =
  ## Return the most specific value for *baseKey* following `.desktop` locale
  ## rules.  Falls back to the first locale match or an empty string.
  if entries.hasKey(baseKey):
    return entries[baseKey]
  for suffix in ["[en_US]", "[en]"]:
    let k = baseKey & suffix
    if entries.hasKey(k): return entries[k]
  for key, val in entries:
    if key.startsWith(baseKey & "["):   # any other locale
      return val
  ""

# ── .desktop parser ─────────────────────────────────────────────────────
proc parseDesktopFile*(path: string): Option[DesktopApp] =
  ## Parse *path* and, if the entry is launchable, return `some(DesktopApp)`.
  ## Criteria (mirrors previous behaviour):
  ##   • has Name & Exec
  ##   • NoDisplay=false, Terminal=false
  ##   • filters out "Settings" / "System" categories
  let fs = newFileStream(path, fmRead)
  if fs.isNil:            # unreadable
    return none(DesktopApp)
  defer: fs.close()

  var inDesktopEntry = false
  var kv = initTable[string, string]()

  for raw in fs.lines:
    let line = raw.strip()
    if line.len == 0 or line.startsWith('#'): continue
    if line.startsWith('[') and line.endsWith(']'):
      inDesktopEntry = (line == "[Desktop Entry]")
      continue
    if inDesktopEntry and "=" in line:
      let parts = line.split('=', 1)
      if parts.len == 2:
        kv[parts[0].strip()] = parts[1].strip()

  let name        = getBestValue(kv, "Name")
  let exec        = getBestValue(kv, "Exec")
  let categories  = kv.getOrDefault("Categories", "")
  let icon        = kv.getOrDefault("Icon", "")
  let noDisplay   = kv.getOrDefault("NoDisplay", "false").toLowerAscii() == "true"
  let terminalApp = kv.getOrDefault("Terminal", "false").toLowerAscii() == "true"

  let launchable =
    name.len > 0 and exec.len > 0 and not noDisplay and not terminalApp and
    not categories.contains("Settings") and not categories.contains("System")

  if launchable:
    result = some(DesktopApp(name: name,
                             exec: exec,
                             hasIcon: icon.len > 0))
  else:
    result = none(DesktopApp)
