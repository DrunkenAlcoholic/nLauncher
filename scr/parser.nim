# scr/parser.nim
import std/[os, strutils, streams, tables, options]
import state 

proc getBaseExec*(exec: string): string =
  let cleanExec = exec.split('%')[0].strip()
  return cleanExec.split(' ')[0].extractFilename()

proc getBestValue*(entries: Table[string, string], baseKey: string): string =
  if entries.hasKey(baseKey): return entries[baseKey]
  if entries.hasKey(baseKey & "[en_US]"): return entries[baseKey & "[en_US]"]
  if entries.hasKey(baseKey & "[en]"): return entries[baseKey & "[en]"]
  for key, val in entries:
    if key.startsWith(baseKey & "["): return val
  return ""

proc parseDesktopFile*(path: string): Option[DesktopApp] =
  # (This is the exact same code as before)
  let stream = newFileStream(path, fmRead)
  if stream == nil: return none(DesktopApp)
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
  let name = getBestValue(entries, "Name")
  let exec = getBestValue(entries, "Exec")
  let categories = entries.getOrDefault("Categories", "")
  let icon = entries.getOrDefault("Icon", "")
  let noDisplay = entries.getOrDefault("NoDisplay", "false").toLower == "true"
  let isTerminalApp = entries.getOrDefault("Terminal", "false").toLower == "true"
  let hasIcon = icon.len > 0
  if noDisplay or isTerminalApp or name.len == 0 or exec.len == 0: return none(DesktopApp)
  if categories.contains("Settings") or categories.contains("System"): return none(DesktopApp)
  return some(DesktopApp(name: name, exec: exec, hasIcon: hasIcon))
