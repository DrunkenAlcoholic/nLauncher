import os
import strutils
import streams
import options
import tables
import sequtils

# We add `hasIcon` to track the most reliable signal of a main application.
type
  DesktopApp = object
    name: string
    exec: string
    hasIcon: bool

proc getBaseExec(exec: string): string =
  let cleanExec = exec.split('%')[0].strip()
  let commandPath = cleanExec.split(' ')[0]
  return commandPath.extractFilename()

# parseDesktopFile now also checks for the presence of an Icon key.
proc parseDesktopFile(path: string): Option[DesktopApp] =
  var name, exec, categories: string
  var noDisplay = false
  var appType = ""
  var isTerminalApp = false
  var hasIcon = false # Default to false

  let stream = newFileStream(path, fmRead)
  if stream == nil: return none(DesktopApp)
  defer: stream.close()

  var inDesktopEntrySection = false
  for line in stream.lines:
    let strippedLine = line.strip()
    if strippedLine == "[Desktop Entry]":
      inDesktopEntrySection = true
      continue
    if not inDesktopEntrySection or strippedLine.startsWith("#") or strippedLine.len == 0:
      continue

    if "=" in strippedLine:
      let parts = strippedLine.split('=', 1)
      let key = parts[0].strip()
      let value = parts[1].strip()

      case key
      of "Name": name = value
      of "Exec": exec = value
      of "Categories": categories = value
      of "Icon":
        if value.len > 0: hasIcon = true # The key exists and has a value
      of "NoDisplay":
        if value.toLower == "true": noDisplay = true
      of "Type":
        appType = value
      of "Terminal":
        if value.toLower == "true": isTerminalApp = true
      else: discard

  # The filtering logic is the same...
  if appType != "Application" or noDisplay or isTerminalApp: return none(DesktopApp)
  if name.len == 0 or exec.len == 0: return none(DesktopApp)
  if categories.contains("Settings") or categories.contains("System"): return none(DesktopApp)

  # ...but now we return the object with the hasIcon flag.
  return some(DesktopApp(name: name, exec: exec, hasIcon: hasIcon))

# --- Main Execution ---

echo "Searching for applications (with Icon-based 'best wins' logic)..."

var apps = initTable[string, DesktopApp]()
let homeDir = getHomeDir()

let searchPaths = [
  homeDir / ".local/share/applications",
  "/usr/share/applications"
]

for basePath in searchPaths:
  if not dirExists(basePath): continue

  for path in walkFiles(basePath / "*.desktop"):
    let appOpt = parseDesktopFile(path)
    if appOpt.isSome:
      let newApp = appOpt.get()
      let baseExec = getBaseExec(newApp.exec)

      if not apps.hasKey(baseExec):
        # First time seeing this app, just add it.
        apps[baseExec] = newApp
      else:
        # We've seen this app before. Decide if the new one is better.
        let existingApp = apps[baseExec]
        var newIsBetter: bool

        # PRIMARY LOGIC: The app with an icon is ALWAYS better.
        if newApp.hasIcon and not existingApp.hasIcon:
          newIsBetter = true
        elif not newApp.hasIcon and existingApp.hasIcon:
          newIsBetter = false
        else:
          # TIE-BREAKER: If both or neither have an icon, fall back
          # to the complexity check as a last resort.
          let newHasFlag = newApp.exec.contains("--")
          let existingHasFlag = existingApp.exec.contains("--")

          if existingHasFlag and not newHasFlag:
            newIsBetter = true
          elif newHasFlag and not existingHasFlag:
            newIsBetter = false
          else:
            let newAppComplexity = newApp.exec.split(' ').len
            let existingAppComplexity = existingApp.exec.split(' ').len
            newIsBetter = newAppComplexity < existingAppComplexity

        if newIsBetter:
          apps[baseExec] = newApp

let uniqueApps = toSeq(apps.values)

echo "Found ", uniqueApps.len, " unique applications."
echo "---"

for i in 0 ..< min(80, uniqueApps.len):
  echo "Name: ", uniqueApps[i].name
  echo "  Exec: ", uniqueApps[i].exec
