#──────────────────────────────────────────────────────────────────────────────
#  gui.nim — X11 + Xft Drawing and Event Handling for nim_launcher
#──────────────────────────────────────────────────────────────────────────────

import strutils, times
import x11/[xlib, xft, x, xrender]
import ./[state, utils]

#──────────────────────────────────────────────────────────────────────────────
#  Globals and Shared X Resources
#──────────────────────────────────────────────────────────────────────────────
var
  font*: PXftFont
  overlayFont*: PXftFont
  xftDraw: PXftDraw

  xftColorFg, xftColorHighlightFg: XftColor
  xftColorBg, xftColorHighlightBg: culong

const
  OverlayDurationMs* = 3_000
  FadeDurationMs* = 500
  OverlayFontDelta = 2

var
  lastThemeSwitchMs*: int64 = 0
  currentThemeName*: string = ""

#──────────────────────────────────────────────────────────────────────────────
#  Exported Procedures
#──────────────────────────────────────────────────────────────────────────────

proc initWindow*()
proc updateGuiColors*()
proc redrawWindow*()
proc notifyThemeChanged*(name: string)
proc drawText*(txt: string, x, y: int, selected: bool)

#──────────────────────────────────────────────────────────────────────────────
#  Utility Procedures
#──────────────────────────────────────────────────────────────────────────────

proc nowMs*(): int64 =
  (epochTime() * 1_000).int64

proc notifyThemeChanged*(name: string) =
  currentThemeName = name
  lastThemeSwitchMs = nowMs()

proc deriveSmallerFont(base: string): string =
  const key = ":size="
  let idx = base.find(key)
  if idx >= 0:
    let sizeStr = base[idx + key.len .. ^1]
    if sizeStr.len > 0 and sizeStr.allCharsInSet({'0' .. '9'}):
      let newSize = max(parseInt(sizeStr) - OverlayFontDelta, 6)
      return base[0 .. idx + key.len - 1] & $newSize
  result = base & ":size=9"

proc loadFont(display: PDisplay, screen: cint, name: string): PXftFont =
  let f = XftFontOpenName(display, screen, name)
  if f.isNil:
    quit "Failed to load font: " & name
  f

proc textWidth(f: PXftFont, txt: string): int =
  var ext: XGlyphInfo
  XftTextExtentsUtf8(display, f, cast[PFcChar8](txt[0].addr), txt.len.cint, ext.addr)
  ext.xOff

proc updateGuiColors*() =
  allocXftColor(config.fgColorHex, xftColorFg)
  allocXftColor(config.highlightFgColorHex, xftColorHighlightFg)
  xftColorBg = config.bgColor
  xftColorHighlightBg = config.highlightBgColor

#──────────────────────────────────────────────────────────────────────────────
#  GUI Setup
#──────────────────────────────────────────────────────────────────────────────

proc initWindow*() =
  display = XOpenDisplay(nil)
  if display.isNil:
    quit "Cannot open X display"
  screen = XDefaultScreen(display)

  font = loadFont(display, screen, config.fontName)
  overlayFont = loadFont(display, screen, deriveSmallerFont(config.fontName))

  config.bgColor = parseColor(config.bgColorHex)
  config.fgColor = parseColor(config.fgColorHex)
  config.highlightBgColor = parseColor(config.highlightBgColorHex)
  config.highlightFgColor = parseColor(config.highlightFgColorHex)
  config.borderColor = parseColor(config.borderColorHex)

  var winX, winY: cint
  if config.centerWindow:
    let sw = XDisplayWidth(display, screen)
    let sh = XDisplayHeight(display, screen)
    winX = cint((sw - config.winWidth) div 2)
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
    display, XRootWindow(display, screen), winX, winY,
    cuint(config.winWidth), cuint(config.winMaxHeight),
    0, CopyFromParent, InputOutput, nil, mask, attrs.addr)

  gc = XDefaultGC(display, screen)

  discard XMapWindow(display, window)
  discard XSetInputFocus(display, window, RevertToParent, CurrentTime)
  discard XFlush(display)

  xftDraw = XftDrawCreate(display, window, DefaultVisual(display, screen), DefaultColormap(display, screen))
  if xftDraw.isNil:
    quit "Failed to create XftDraw"

#──────────────────────────────────────────────────────────────────────────────
#  Text Rendering
#──────────────────────────────────────────────────────────────────────────────

proc drawText*(txt: string, x, y: int, selected: bool) =
  let fg = if selected: xftColorHighlightFg.addr else: xftColorFg.addr
  let bg = if selected: xftColorHighlightBg else: xftColorBg

  let asc = font.ascent
  let desc = font.descent
  let rectY = y - asc - ((config.lineHeight - (asc + desc)) shr 1) - 1
  let rectH = config.lineHeight + 2
  let marginX = max(6, config.borderWidth + 2)
  let marginW = config.winWidth - marginX * 2

  discard XSetForeground(display, gc, bg)
  discard XFillRectangle(display, window, gc, cint(marginX), cint(rectY), cuint(marginW), cuint(rectH))

  XftDrawStringUtf8(xftDraw, fg, font, cint(x), cint(y), cast[PFcChar8](txt[0].addr), txt.len.cint)

#──────────────────────────────────────────────────────────────────────────────
#  Overlay Text (Theme Indicator)
#──────────────────────────────────────────────────────────────────────────────

proc drawThemeOverlay(winW, winH: int) =
  if lastThemeSwitchMs == 0 or overlayFont.isNil: return
  let elapsed = nowMs() - lastThemeSwitchMs
  if elapsed > OverlayDurationMs: return

  var alpha = 1.0
  if elapsed > OverlayDurationMs - FadeDurationMs:
    alpha = 1.0 - (elapsed - (OverlayDurationMs - FadeDurationMs)).float / FadeDurationMs.float

  let txt = currentThemeName
  let txtW = overlayFont.textWidth(txt)
  let txtH = overlayFont.ascent + overlayFont.descent
  const pad = 6
  let x = winW - txtW - pad - 4
  let y = winH - txtH - pad - 4

  discard XSetForeground(display, gc, xftColorBg)
  discard XFillRectangle(display, window, gc, cint(x - 4), cint(y - 4), cuint(txtW + 8), cuint(txtH + 8))

  XftDrawStringUtf8(xftDraw, xftColorFg.addr, overlayFont, cint(x), cint(y + overlayFont.ascent), cast[PFcChar8](txt[0].addr), txt.len.cint)

#──────────────────────────────────────────────────────────────────────────────
#  Redraw Entire Launcher Window
#──────────────────────────────────────────────────────────────────────────────

proc redrawWindow*() =
  discard XSetForeground(display, gc, config.bgColor)
  discard XFillRectangle(display, window, gc, 0, 0, cuint(config.winWidth), cuint(config.winMaxHeight))

  if config.borderWidth > 0:
    discard XSetForeground(display, gc, config.borderColor)
    for i in 0 ..< config.borderWidth:
      discard XDrawRectangle(display, window, gc, cint(i), cint(i), cuint(config.winWidth - 1 - i * 2), cuint(config.winMaxHeight - 1 - i * 2))

  drawText(config.prompt & inputText & config.cursor, 20, 30, false)

  let listStartY = 30 + config.lineHeight
  for vis in 0 ..< config.maxVisibleItems:
    let idx = viewOffset + vis
    if idx >= filteredApps.len: break
    let app = filteredApps[idx]
    let y = listStartY + vis * config.lineHeight
    let sel = idx == selectedIndex
    if sel:
      discard XSetForeground(display, gc, config.highlightBgColor)
      discard XFillRectangle(display, window, gc, 10, cint(y - config.lineHeight + 5), cuint(config.winWidth - 20), cuint(config.lineHeight))
    drawText(app.name, 20, y, sel)

  drawThemeOverlay(config.winWidth, config.winMaxHeight)
  discard XFlush(display)
