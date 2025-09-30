## gui.nim — X11 / Xft drawing and window management
## MIT; see LICENSE for details.
##
## Responsible for:
## • Creating the X11 window
## • Loading fonts and allocating colours from Config
## • Rendering prompt, list rows (with match highlighting), borders, and overlays

import std/[strutils, times, os]
import x11/[xlib, xft, x, xrender]
import ./[state, utils] # display*, screen*, window*, gc*, config …

# ── Global Xft handles ──────────────────────────────────────────────────
var
  font*: PXftFont        ## primary UI font (config.fontName)
  overlayFont*: PXftFont ## smaller font for theme-name/time overlay
  boldFont*: PXftFont    ## used for matched-character overlays
  xftDraw: PXftDraw

  xftColorFg, xftColorHighlightFg: XftColor
  xftColorMatchFg: XftColor
  xftColorBg, xftColorHighlightBg: culong
  overlayColor: XftColor ## base colour for theme overlay

# ── Overlay timing state ────────────────────────────────────────────────
const
  FadeDurationMs* = 500
  OverlayFontDelta = 2 ## overlay font is base size − 2pt (min 6pt)

var
  lastThemeSwitchMs*: int64 = 0
  currentThemeName: string = ""
  statusText*: string = ""
  statusUntilMs*: int64 = 0

proc nowMs*(): int64 =
  ## Milliseconds since Unix epoch.
  (epochTime() * 1_000).int64

proc notifyThemeChanged*(name: string) =
  ## Called by the launcher whenever the active theme changes.
  currentThemeName = name
  lastThemeSwitchMs = nowMs()
  overlayColor = xftColorFg
  overlayColor.color.alpha = 65535'u16

proc notifyStatus*(text: string; durationMs = 800) =
  ## Show a short-lived status overlay (e.g., "Searching…").
  statusText = text
  statusUntilMs = nowMs() + durationMs

proc clearStatus*() =
  statusText = ""
  statusUntilMs = 0

# ── Font helpers ────────────────────────────────────────────────────────
proc deriveBoldFont(base: string): string =
  ## Ensure a bold face request via fontconfig (preserves other attributes).
  if base.contains(":weight="):
    var s = base
    let i = s.find(":weight=")
    if i >= 0:
      var j = i + 8
      while j < s.len and s[j] != ':': inc j
      return s[0 ..< i] & ":weight=bold" & (if j < s.len: s[j .. ^1] else: "")
  result = base & ":weight=bold"

proc deriveSmallerFont(base: string): string =
  ## Derive a slightly smaller variant from *base* by decreasing `:size=`.
  const key = ":size="
  let idx = base.find(key)
  if idx >= 0:
    var j = idx + key.len
    var n = 0
    while j < base.len and base[j].isDigit:
      n = n * 10 + (ord(base[j]) - ord('0'))
      inc j
    if n > 0:
      let newSize = max(n - OverlayFontDelta, 6)
      if j <= base.high:
        return base[0 .. idx + key.len - 1] & $newSize & base[j .. ^1]
      else:
        return base[0 .. idx + key.len - 1] & $newSize
  result = base & ":size=9"

proc loadFont(display: PDisplay, screen: cint, name: string): PXftFont =
  ## Load a font by pattern; quit with a helpful message on failure.
  let f = XftFontOpenName(display, screen, name)
  if f.isNil:
    quit "Failed to load font: " & name
  f

proc updateGuiColors*() =
  ## Resolve hex → Xft colours and X pixel values from current config.
  try:
    allocXftColor(config.fgColorHex, xftColorFg)
    allocXftColor(config.highlightFgColorHex, xftColorHighlightFg)
    allocXftColor(config.matchFgColorHex, xftColorMatchFg)
  except CatchableError:
    quit "Invalid colour in theme configuration"
  xftColorBg = config.bgColor
  xftColorHighlightBg = config.highlightBgColor

proc textWidth(txt: string; useOverlayFont = false): cint =
  ## Return pixel width of *txt* using the primary or overlay font.
  var ext: XGlyphInfo
  let pStr = cast[PFcChar8](txt.cstring)
  let pExt = cast[PXGlyphInfo](addr ext)
  if useOverlayFont:
    XftTextExtentsUtf8(display, overlayFont, pStr, cint(txt.len), pExt)
  else:
    XftTextExtentsUtf8(display, font, pStr, cint(txt.len), pExt)
  ext.xOff

# ── Theme overlay (fades in/out at top-right) ───────────────────────────
proc drawThemeOverlay() =
  ## Draw the active theme name for a short fade after switching.
  if currentThemeName.len == 0: return
  let elapsed = nowMs() - lastThemeSwitchMs
  if elapsed > FadeDurationMs: return

  let alpha = 1.0 - (elapsed.float / FadeDurationMs.float) # 1 → 0
  var col = overlayColor
  col.color.alpha = uint16(alpha * 65535)

  const marginX = 8
  const marginY = 6
  let tx = (config.winWidth - marginX - textWidth(currentThemeName, true)).cint
  let ty = (marginY + overlayFont.ascent).cint

  XftDrawStringUtf8(
    xftDraw,
    cast[PXftColor](addr col),
    overlayFont,
    tx, ty,
    cast[PFcChar8](currentThemeName[0].addr),
    currentThemeName.len.cint
  )

proc drawStatusOverlay() =
  ## Draw transient status text near the top-right, below theme overlay if present.
  if statusText.len == 0: return
  if nowMs() > statusUntilMs: return

  const marginX = 8
  const marginY = 6

  ## Start at top-right
  var ty = (marginY + overlayFont.ascent).cint

  ## If theme name is currently fading, nudge status below it
  let themeActive = (currentThemeName.len > 0) and ((nowMs() - lastThemeSwitchMs) <= FadeDurationMs)
  if themeActive:
    ty += (overlayFont.ascent + 4).cint

  let tx = (config.winWidth - marginX - textWidth(statusText, true)).cint

  XftDrawStringUtf8(
    xftDraw,
    cast[PXftColor](addr xftColorFg),
    overlayFont,
    tx, ty,
    cast[PFcChar8](statusText[0].addr),
    statusText.len.cint
  )


# ── Initialization ──────────────────────────────────────────────────────
proc initGui*() =
  ## Create the X11 window, load fonts, set up colours and drawing targets.
  display = XOpenDisplay(nil)
  if display.isNil:
    quit "Cannot open X display"
  screen = XDefaultScreen(display)

  ## Fonts
  font = loadFont(display, screen, config.fontName)
  overlayFont = loadFont(display, screen, deriveSmallerFont(config.fontName))
  boldFont = loadFont(display, screen, deriveBoldFont(config.fontName))

  ## timeIt "UpdateGuiColors":
  ##  updateGuiColors()

  timeIt "Create Window":
    var winX, winY: cint
    if config.centerWindow:
      let sw = XDisplayWidth(display, screen)
      let sh = XDisplayHeight(display, screen)
      winX = cint((sw - config.winWidth) div 2)
      case config.verticalAlign
      of "top":
        winY = 50
      of "center":
        winY = cint((sh - config.winMaxHeight) div 2)
      else:
        winY = cint(sh div 3) # "one-third"
    else:
      winX = cint(config.positionX)
      winY = cint(config.positionY)

    var attrs: XSetWindowAttributes
    let isWayland = getEnv("WAYLAND_DISPLAY") != ""
    attrs.override_redirect = if isWayland: 0 else: 1
    attrs.background_pixel = config.bgColor
    attrs.border_pixel = config.borderColor

    let valueMask = culong(
      CWBackPixel or CWBorderPixel or
      (if not isWayland: CWOverrideRedirect else: 0)
    )

    window = XCreateWindow(
      display,
      XRootWindow(display, screen),
      winX.cint, winY.cint,
      cuint(config.winWidth),
      cuint(config.winMaxHeight),
      cuint(config.borderWidth),
      DefaultDepth(display, screen).cint,
      cuint(InputOutput),
      DefaultVisual(display, screen),
      valueMask,
      cast[PXSetWindowAttributes](addr attrs)
    )

    if isWayland:
      ## Hint to favour a borderless dialog-like surface
      let wmTypeAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE", 0)
      let dialogAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE_DIALOG", 0)
      let atomAtom = XInternAtom(display, "ATOM", 0)
      discard XChangeProperty(
        display, window,
        wmTypeAtom, atomAtom,
        32.cint, PropModeReplace,
        cast[Pcuchar](addr dialogAtom), 1.cint
      )

      ## _MOTIF_WM_HINTS: disable decorations where respected
      const MWM_HINTS_DECORATIONS = 2'u32
      let mwmHintsAtom = XInternAtom(display, "_MOTIF_WM_HINTS", 0)
      var mwmHints: array[5, uint64]
      mwmHints[0] = MWM_HINTS_DECORATIONS
      mwmHints[2] = 0'u64
      discard XChangeProperty(
        display, window,
        mwmHintsAtom, mwmHintsAtom,
        32.cint, PropModeReplace,
        cast[Pcuchar](addr mwmHints), mwmHints.len.cint
      )

    discard XStoreName(display, window, "nLauncher")
    discard XSelectInput(
      display, window,
      ExposureMask or KeyPressMask or
      FocusChangeMask or StructureNotifyMask or ButtonPressMask
    )
    discard XMapWindow(display, window)
    discard XFlush(display)

    discard XGrabPointer(
      display,
      window,
      1,
      ButtonPressMask,
      GrabModeAsync, GrabModeAsync,
      0, 0,
      CurrentTime
    )

    if not isWayland:
      discard XSetInputFocus(display, window, RevertToParent, CurrentTime)

    gc = XCreateGC(display, window, 0, nil)
    xftDraw = XftDrawCreate(
      display, window,
      DefaultVisual(display, screen),
      DefaultColormap(display, screen)
    )

# ── Drawing routines ────────────────────────────────────────────────────
proc drawText*(txt: string; x, y: cint; spans: seq[(int, int)] = @[];
    selected = false) =
  ## Draw a single line with optional highlighted spans.
  let bgCol = if selected: xftColorHighlightBg else: xftColorBg
  discard XSetForeground(display, gc, bgCol)
  discard XFillRectangle(
    display, window, gc,
    x, y - font.ascent,
    cuint(config.winWidth),
    cuint(config.lineHeight)
  )

  ## Base text
  let baseFg = if selected: xftColorHighlightFg else: xftColorFg
  if txt.len > 0:
    XftDrawStringUtf8(
      xftDraw,
      cast[PXftColor](addr baseFg),
      font,
      x, y,
      cast[PFcChar8](txt[0].addr),
      txt.len.cint
    )

  ## Overlay matched segments (bold + match colour)
  for (s, len) in spans:
    if len <= 0 or s < 0 or s >= txt.len: continue
    let e = min(s + len, txt.len)
    if e <= s: continue
    let pre = if s > 0: txt[0 ..< s] else: ""
    let seg = txt[s ..< e]
    if seg.len == 0: continue
    let xPos = x + textWidth(pre)
    XftDrawStringUtf8(
      xftDraw,
      cast[PXftColor](addr xftColorMatchFg),
      boldFont,
      xPos, y,
      cast[PFcChar8](seg[0].addr),
      seg.len.cint
    )

proc redrawWindow*() =
  ## Full-frame redraw (prompt, list, overlay, border).
  discard XSetForeground(display, gc, config.bgColor)
  discard XFillRectangle(
    display, window, gc,
    0, 0,
    cuint(config.winWidth),
    cuint(config.winMaxHeight)
  )

  var y: cint = font.ascent + 8
  let promptLine = config.prompt & inputText & (
      if benchMode: "" else: config.cursor)
  drawText(promptLine, 12, y)
  y += config.lineHeight.cint + 6

  let total = filteredApps.len
  let maxRows = config.maxVisibleItems
  let start = viewOffset
  let finish = min(viewOffset + maxRows, total)

  for idx in start ..< finish:
    let app = filteredApps[idx]
    let selected = (idx == selectedIndex)
    drawText(app.name, 12, y, matchSpans[idx], selected)
    y += config.lineHeight.cint

  ## Theme overlay (top-right)
  drawThemeOverlay()
  drawStatusOverlay()

  ## Small clock (bottom-right, overlay font)
  let nowStr = now().format("HH:mm")
  let cw = textWidth(nowStr, true)
  let cx = config.winWidth - int(cw) - 2
  let cy = config.winMaxHeight - 8
  XftDrawStringUtf8(
    xftDraw,
    cast[PXftColor](addr xftColorFg),
    overlayFont,
    cint(cx), cint(cy),
    cast[PFcChar8](nowStr[0].addr),
    nowStr.len.cint
  )

  ## Border
  if config.borderWidth > 0:
    discard XSetForeground(display, gc, config.borderColor)
    for i in 0 ..< config.borderWidth:
      discard XDrawRectangle(
        display, window, gc,
        i.cint, i.cint,
        cuint(config.winWidth - 1 - i * 2),
        cuint(config.winMaxHeight - 1 - i * 2)
      )

  discard XFlush(display)
