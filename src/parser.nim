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
  ## Parses a single .desktop file and returns a DesktopApp object if it's a
  ## valid, launchable, graphical application.

  let tStart = epochTime()

  let stream = newFileStream(path, fmRead)
  if stream == nil:
    let tEnd = epochTime()
    echo "[PARSE FAIL] ", path, " in ", tEnd - tStart, "s"
    return none(DesktopApp)
  defer: stream.close()

  var inDesktopEntrySection = false
  # We use a table to collect all key-value pairs from the main section.
  # This is tolerant of duplicate keys, which are common for localization.
  var entries = initTable[string, string]()

  for line in stream.lines:
    let strippedLine = line.strip()
    if strippedLine.len == 0 or strippedLine.startsWith("#"): continue

    # Check for section headers to ensure we're in the right place.
    if strippedLine.startsWith("[") and strippedLine.endsWith("]"):
      inDesktopEntrySection = (strippedLine == "[Desktop Entry]")
      continue

    # Only process lines if we're in the "[Desktop Entry]" section.
    if inDesktopEntrySection and "=" in strippedLine:
      let parts = strippedLine.split('=', 1)
      if parts.len == 2:
        entries[parts[0].strip()] = parts[1].strip()

  # -- Extract and Filter --
  
  # Use our helper to get the most important, potentially localized values.
  let name = getBestValue(entries, "Name")
  let exec = getBestValue(entries, "Exec")

  # For simple values, we can get them directly.
  let categories = entries.getOrDefault("Categories", "")
  let icon = entries.getOrDefault("Icon", "")
  let noDisplay = entries.getOrDefault("NoDisplay", "false").toLower == "true"
  let isTerminalApp = entries.getOrDefault("Terminal", "false").toLower == "true"
  let hasIcon = icon.len > 0

  # Apply our filtering rules to exclude unwanted entries.
  let valid =
    not noDisplay and not isTerminalApp and name.len > 0 and exec.len > 0 and
    not categories.contains("Settings") and not categories.contains("System")
  
  let tEnd = epochTime()
  let duration = tEnd - tStart
  if duration > 0.001:  # Highlight anything slower than 1ms
    echo "[PARSE] ", path, " took ", duration * 1000, " ms"

  # If all checks pass, we have a valid application.
  if valid:
    return some(DesktopApp(name: name, exec: exec, hasIcon: hasIcon))
  else:
    return none(DesktopApp)