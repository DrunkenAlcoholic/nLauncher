# scr/parser.nim
#
# Handles the logic for finding and parsing .desktop files to create a list
# of launchable applications.

import std/[os, strutils, streams, tables, times, options]
import state 

proc getBaseExec*(exec: string): string =
  ## Extracts the base executable name from a full `Exec` command string.
  ## This is used for de-duplicating applications.
  ## e.g., "brave --incognito %U" -> "brave"
  let cleanExec = exec.split('%')[0].strip()
  return cleanExec.split(' ')[0].extractFilename()

proc getBestValue*(entries: Table[string, string], baseKey: string): string =
  ## Intelligently selects the best value for a key from a table of entries,
  ## correctly handling localization in .desktop files.
  
  # Priority 1: The simple, non-localized key (e.g., "Name"). This is preferred.
  if entries.hasKey(baseKey): return entries[baseKey]

  # Priority 2: A specific English key, as a good fallback.
  if entries.hasKey(baseKey & "[en_US]"): return entries[baseKey & "[en_US]"]
  if entries.hasKey(baseKey & "[en]"): return entries[baseKey & "[en]"]

  # Priority 3: The first available localized key of any other language.
  for key, val in entries:
    if key.startsWith(baseKey & "["): return val
  
  # If all else fails, return an empty string.
  return ""

proc parseDesktopFile*(path: string): Option[DesktopApp] =
  #let tStart = epochTime()

  let stream = newFileStream(path, fmRead)
  if stream == nil:
    echo "[PARSE FAIL] ", path, " (file not readable)"
    return none(DesktopApp)
  defer: stream.close()

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
    name.len > 0 and exec.len > 0 and
    not noDisplay and not isTerminalApp and
    not categories.contains("Settings") and not categories.contains("System")

  #let duration = epochTime() - tStart
  #if duration > 0.001:
  #  echo "[PARSE] ", path, " took ", duration * 1000, " ms"

  if valid:
    return some(DesktopApp(name: name, exec: exec, hasIcon: hasIcon))
  else:
    return none(DesktopApp)
