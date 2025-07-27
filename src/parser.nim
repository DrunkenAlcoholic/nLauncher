# src/parser.nim
#
# Parses .desktop files to build the application list.

#──────────────────────────────────────────────────────────────────────────────
#  Imports
#──────────────────────────────────────────────────────────────────────────────
import std/[os, strutils, streams, tables, options]
import state

#──────────────────────────────────────────────────────────────────────────────
#  Exec‑line helper
#──────────────────────────────────────────────────────────────────────────────
proc getBaseExec*(exec: string): string =
  ## Extracts the base executable name from an Exec string.
  let cleanExec = exec.split('%')[0].strip()
  return cleanExec.split(' ')[0].extractFilename()

#──────────────────────────────────────────────────────────────────────────────
#  .desktop file parser
#──────────────────────────────────────────────────────────────────────────────
proc getBestValue*(entries: Table[string, string], baseKey: string): string =
  ## Selects the best value for a key, handling localization.
  if entries.hasKey(baseKey):
    return entries[baseKey]
  if entries.hasKey(baseKey & "[en_US]"):
    return entries[baseKey & "[en_US]"]
  if entries.hasKey(baseKey & "[en]"):
    return entries[baseKey & "[en]"]
  for key, val in entries:
    if key.startsWith(baseKey & "["):
      return val
  return ""

proc parseDesktopFile*(path: string): Option[DesktopApp] =
  ## Parses a .desktop file and returns a DesktopApp if valid.
  let stream = newFileStream(path, fmRead)
  if stream == nil:
    echo "[PARSE FAIL] ", path, " (file not readable)"
    return none(DesktopApp)
  defer:
    stream.close()

  var inDesktopEntrySection = false
  var entries = initTable[string, string]()

  for line in stream.lines:
    let stripped = line.strip()
    if stripped.len == 0 or stripped.startsWith("#"):
      continue
    if stripped.startsWith("[") and stripped.endsWith("]"):
      inDesktopEntrySection = (stripped == "[Desktop Entry]")
      continue
    if inDesktopEntrySection and "=" in stripped:
      let parts = stripped.split('=', 1)
      if parts.len == 2:
        entries[parts[0].strip()] = parts[1].strip()

  let name = getBestValue(entries, "Name")
  let exec = getBestValue(entries, "Exec")
  let categories = entries.getOrDefault("Categories", "")
  let icon = entries.getOrDefault("Icon", "")
  let noDisplay = entries.getOrDefault("NoDisplay", "false").toLowerAscii() == "true"
  let isTerminalApp = entries.getOrDefault("Terminal", "false").toLowerAscii() == "true"
  let hasIcon = icon.len > 0

  let valid =
    name.len > 0 and exec.len > 0 and not noDisplay and not isTerminalApp and
    not categories.contains("Settings") and not categories.contains("System")

  if valid:
    return some(DesktopApp(name: name, exec: exec, hasIcon: hasIcon))
  else:
    return none(DesktopApp)
