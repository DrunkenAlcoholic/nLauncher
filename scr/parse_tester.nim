import os
import strutils
import streams
import tables

# This helper function applies our priority logic to find the best value.
proc getBestValue(entries: Table[string, string], baseKey: string): string =
  # Priority 1: The simple, non-localized key (e.g., "Name")
  if entries.hasKey(baseKey): return entries[baseKey]
  # Priority 2: A specific English key (e.g., "Name[en_US]")
  if entries.hasKey(baseKey & "[en_US]"): return entries[baseKey & "[en_US]"]
  if entries.hasKey(baseKey & "[en]"): return entries[baseKey & "[en]"]
  # Priority 3: The first localized key we can find
  for key, val in entries:
    if key.startsWith(baseKey & "["):
      return val
  # If all else fails, return empty
  return ""

proc parseSingleFile(path: string) =
  if not fileExists(path):
    echo "Error: File not found at '", path, "'"
    return

  echo "--- Parsing Results for: ", path, " ---"
  
  let stream = newFileStream(path, fmRead)
  if stream == nil:
    echo "Error: Could not open file."
    return
  defer: stream.close()

  var inDesktopEntrySection = false
  var entries = initTable[string, string]()

  for line in stream.lines:
    let strippedLine = line.strip()
    if strippedLine.len == 0 or strippedLine.startsWith("#"): continue

    if strippedLine.startsWith("[") and strippedLine.endsWith("]"):
      inDesktopEntrySection = (strippedLine == "[Desktop Entry]")
      continue

    if inDesktopEntrySection and "=" in strippedLine:
      let parts = strippedLine.split('=', 1)
      if parts.len == 2:
        entries[parts[0].strip()] = parts[1].strip()

  if entries.len == 0:
    echo "No entries found in [Desktop Entry] section."
    return

  # Use our helper to get the most important values
  let bestName = getBestValue(entries, "Name")
  let bestExec = getBestValue(entries, "Exec")
  let icon = entries.getOrDefault("Icon", "N/A")
  let categories = entries.getOrDefault("Categories", "N/A")

  echo "\n[Best Values Extracted]"
  echo "  Name:       ", bestName
  echo "  Exec:       ", bestExec
  echo "  Icon:       ", icon
  echo "  Categories: ", categories

  echo "\n[All Found Entries in [Desktop Entry]]"
  for key, val in entries:
    echo "  ", key, " = ", val
  echo "--- End of Report ---"

# --- Main Program Logic ---
when isMainModule:
  if paramCount() < 1:
    echo "Usage: nim c -r parse_tester.nim <path_to_desktop_file>"
  else:
    let filePath = paramStr(1)
    parseSingleFile(filePath)