# src/gui.nim

#──────────────────────────────────────────────────────────────────────────────
#  Imports
#──────────────────────────────────────────────────────────────────────────────
import strutils, times
import x11/[xlib, xft, x, xrender]
import state

#──────────────────────────────────────────────────────────────────────────────
#  Global Xft / Xlib handles
#──────────────────────────────────────────────────────────────────────────────
var
  font*: PXftFont ## Primary UI font (config.fontName)
  overlayFont*: PXftFont ## Smaller font for theme overlay
  xftDraw: PXftDraw
  xftColorFg, xftColorHighlightFg: XftColor
  xftColorBg, xftColorHighlightBg: culong

# state.nim already declares: display*, screen*, window*, graphicsContext*

#──────────────────────────────────────────────────────────────────────────────
#  Theme‑Overlay — constants, state, helpers
#──────────────────────────────────────────────────────────────────────────────
const
  OverlayDurationMs* = 3_000
  FadeDurationMs* = 500
  OverlayFontDelta = 2 ## overlay font is `size - OverlayFontDelta`

var
  lastThemeSwitchMs*: int64 = 0
  currentThemeName*: string = ""

proc nowMs*(): int64 =
  (epochTime() * 1_000).int64

proc notifyThemeChanged*(name: string) =
  currentThemeName = name
  lastThemeSwitchMs = nowMs()

#──────────────────────────────────────────────────────────────────────────────
#  Font helpers
#──────────────────────────────────────────────────────────────────────────────
proc deriveSmallerFont(base: string): string =
  ## If base contains ":size=N", reduce N, else append ":size=9".
  const key = ":size="
  let idx = base.find(key)
  if idx >= 0:
    let sizeStr = base[idx + key.len .. ^1]
    if sizeStr.len > 0 and sizeStr.allCharsInSet({'0' .. '9'}):
      let newSize = max(parseInt(sizeStr) - OverlayFontDelta, 6)
      return base[0 .. idx + key.len - 1] & $newSize
  # fallback
  return base & ":size=9"

proc loadFont(display: PDisplay, screen: cint, name: string): PXftFont =
  let f = XftFontOpenName(display, screen, name)
  if f.isNil:
    quit "Failed to load font: " & name
  f

#──────────────────────────────────────────────────────────────────────────────
#  Colour helpers (unchanged)
#──────────────────────────────────────────────────────────────────────────────
proc parseColor*(hex: string): culong =
  var r, g, b: int
  if hex.startsWith("#") and hex.len == 7:
    r = parseHexInt(hex[1 .. 2])
    g = parseHexInt(hex[3 .. 4])
    b = parseHexInt(hex[5 .. 6])
  else:
    echo "Warning: invalid colour format: ", hex
    return 0
  var c: XColor
  c.red = uint16(r * 257)
  c.green = uint16(g * 257)
  c.blue = uint16(b * 257)
  c.flags = cast[cchar](DoRed or DoGreen or DoBlue)
  if XAllocColor(display, XDefaultColormap(display, screen), c.addr) == 0:
    echo "Warning: XAllocColor failed for ", hex
    return 0
  c.pixel

proc allocXftColor(hex: string, dest: var XftColor) =
  var r, g, b: int
  if hex.startsWith("#") and hex.len == 7:
    r = parseHexInt(hex[1 .. 2])
    g = parseHexInt(hex[3 .. 4])
    b = parseHexInt(hex[5 .. 6])
  else:
    quit "Invalid colour hex: " & hex
  var rc: XRenderColor
  rc.red = uint16(r * 257)
  rc.green = uint16(g * 257)
  rc.blue = uint16(b * 257)
  rc.alpha = 65535
  if XftColorAllocValue(
    display,
    DefaultVisual(display, screen),
    DefaultColormap(display, screen),
    rc.addr,
    dest.addr,
  ) == 0:
    quit "XftColorAllocValue failed for " & hex

proc updateGuiColors*() =
  allocXftColor(config.fgColorHex, xftColorFg)
  allocXftColor(config.highlightFgColorHex, xftColorHighlightFg)
  xftColorBg = config.bgColor
  xftColorHighlightBg = config.highlightBgColor

#──────────────────────────────────────────────────────────────────────────────
#  Text metrics helper (works with any font)
#──────────────────────────────────────────────────────────────────────────────
proc textWidth(f: PXftFont, txt: string): int =
  var ext: XGlyphInfo
  XftTextExtentsUtf8(display, f, cast[PFcChar8](txt[0].addr), txt.len.cint, addr ext)
  ext.xOff

#──────────────────────────────────────────────────────────────────────────────
#  Overlay draw proc (uses overlayFont)
#──────────────────────────────────────────────────────────────────────────────
proc drawThemeOverlay(winW, winH: int) =
  if lastThemeSwitchMs == 0 or overlayFont.isNil:
    return
  let elapsed = nowMs() - lastThemeSwitchMs
  if elapsed > OverlayDurationMs:
    return

  var alpha: float = 1.0
  if elapsed > OverlayDurationMs - FadeDurationMs:
    alpha =
      1.0 - (elapsed - (OverlayDurationMs - FadeDurationMs)).float / FadeDurationMs.float

  let bgPix = xftColorBg
  let fg = xftColorFg.addr
  let txt = currentThemeName
  let txtW = overlayFont.textWidth(txt)
  let txtH = overlayFont.ascent + overlayFont.descent
  const pad = 6
  let x = winW - txtW - pad - 4
  let y = winH - txtH - pad - 4

  discard XSetForeground(display, graphicsContext, bgPix)
  discard XFillRectangle(
    display,
    window,
    graphicsContext,
    cint(x - 4),
    cint(y - 4),
    cuint(txtW + 8),
    cuint(txtH + 8),
  )

  XftDrawStringUtf8(
    xftDraw,
    fg,
    overlayFont,
    cint(x),
    cint(y + overlayFont.ascent),
    cast[PFcChar8](txt[0].addr),
    txt.len.cint,
  )

#──────────────────────────────────────────────────────────────────────────────
#  initGui — create window, load fonts/colours, etc.
#──────────────────────────────────────────────────────────────────────────────
proc initGui*() =
  display = XOpenDisplay(nil)
  if display.isNil:
    quit "Cannot open X display"
  screen = XDefaultScreen(display)

  font = loadFont(display, screen, config.fontName)
  overlayFont = loadFont(display, screen, deriveSmallerFont(config.fontName))

  # Convert colours
  config.bgColor = parseColor(config.bgColorHex)
  config.fgColor = parseColor(config.fgColorHex)
  config.highlightBgColor = parseColor(config.highlightBgColorHex)
  config.highlightFgColor = parseColor(config.highlightFgColorHex)
  config.borderColor = parseColor(config.borderColorHex)

  # Window geometry
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
      winY = cint((sh - config.winMaxHeight) div 3)
  else:
    winX = cint(config.positionX)
    winY = cint(config.positionY)

  var attrs: XSetWindowAttributes
  attrs.override_redirect = true.XBool
  attrs.background_pixel = config.bgColor
  attrs.event_mask = KeyPressMask or ExposureMask or FocusChangeMask
  let mask: culong = CWOverrideRedirect or CWBackPixel or CWEventMask

  window = XCreateWindow(
    display,
    XRootWindow(display, screen),
    winX,
    winY,
    cuint(config.winWidth),
    cuint(config.winMaxHeight),
    0,
    CopyFromParent,
    InputOutput,
    nil,
    mask,
    attrs.addr,
  )
  graphicsContext = XDefaultGC(display, screen)

  discard XMapWindow(display, window)
  discard XSetInputFocus(display, window, RevertToParent, CurrentTime)
  discard XFlush(display)

  xftDraw = XftDrawCreate(
    display, window, DefaultVisual(display, screen), DefaultColormap(display, screen)
  )
  if xftDraw.isNil:
    quit "Failed to create XftDraw"

  updateGuiColors()
  echo "initGui(): main font = ",
    config.fontName, " | overlay font = ", deriveSmallerFont(config.fontName)

#──────────────────────────────────────────────────────────────────────────────
#  drawText, redrawWindow (unchanged except drawThemeOverlay uses overlayFont)
#──────────────────────────────────────────────────────────────────────────────
proc drawText*(txt: string, x, y: int, selected: bool) =
  ## Draw a single line of text, with optional selection highlight.
  if font.isNil or xftDraw.isNil:
    return

  let fg = (if selected: xftColorHighlightFg.addr else: xftColorFg.addr)
  let bg = (if selected: xftColorHighlightBg else: xftColorBg)

  let asc = font.ascent
  let desc = font.descent
  let rectY = y - asc - ((config.lineHeight - (asc + desc)) shr 1) - 1
  let rectH = config.lineHeight + 2
  let marginX = max(6, config.borderWidth + 2)
  let marginW = config.winWidth - marginX * 2

  discard XSetForeground(display, graphicsContext, bg)
  discard XFillRectangle(
    display,
    window,
    graphicsContext,
    cint(marginX),
    cint(rectY),
    cuint(marginW),
    cuint(rectH),
  )

  XftDrawStringUtf8(
    xftDraw, fg, font, cint(x), cint(y), cast[PFcChar8](txt[0].addr), txt.len.cint
  )

#──────────────────────────────────────────────────────────────────────────────
#  Main redraw function (called on Expose & after state changes)
#──────────────────────────────────────────────────────────────────────────────
proc redrawWindow*() =
  ## Redraws the entire launcher window contents.
  discard XSetForeground(display, graphicsContext, config.bgColor)
  discard XFillRectangle(
    display,
    window,
    graphicsContext,
    0,
    0,
    cuint(config.winWidth),
    cuint(config.winMaxHeight),
  )

  # Optional decorative border
  if config.borderWidth > 0:
    discard XSetForeground(display, graphicsContext, config.borderColor)
    for i in 0 ..< config.borderWidth:
      discard XDrawRectangle(
        display,
        window,
        graphicsContext,
        cint(i),
        cint(i),
        cuint(config.winWidth - 1 - i * 2),
        cuint(config.winMaxHeight - 1 - i * 2),
      )

  # Input prompt + user query line
  drawText(config.prompt & inputText & config.cursor, 20, 30, false)

  # Application list
  let listStartY = 30 + config.lineHeight
  for visIdx in 0 ..< config.maxVisibleItems:
    let appIdx = viewOffset + visIdx
    if appIdx >= filteredApps.len:
      break

    let app = filteredApps[appIdx]
    let yPos = listStartY + visIdx * config.lineHeight
    let sel = (appIdx == selectedIndex)

    if sel:
      discard XSetForeground(display, graphicsContext, config.highlightBgColor)
      discard XFillRectangle(
        display,
        window,
        graphicsContext,
        10,
        cint(yPos - config.lineHeight + 5),
        cuint(config.winWidth - 20),
        cuint(config.lineHeight),
      )

    drawText(app.name, 20, yPos, sel)

  # Theme‑name overlay (auto‑hides after OverlayDurationMs)
  drawThemeOverlay(config.winWidth, config.winMaxHeight)

  discard XFlush(display)

#──────────────────────────────────────────────────────────────────────────────
#  End of gui.nim
#──────────────────────────────────────────────────────────────────────────────
