#──────────────────────────────────────────────────────────────────────────────
#  gui.nim — X11 / Xft drawing and window management
#  GNU GPL v3 (or later); see LICENSE for details.
#──────────────────────────────────────────────────────────────────────────────
#  Imports
#──────────────────────────────────────────────────────────────────────────────
import strutils, times
import x11/[xlib, xft, x, xrender]
import ./[state, utils]          # display*, screen*, window*, gc*, config …

#──────────────────────────────────────────────────────────────────────────────
#  Global Xft handles
#──────────────────────────────────────────────────────────────────────────────
var
  font*: PXftFont                ## primary UI font (config.fontName)
  overlayFont*: PXftFont         ## smaller font for theme‑name overlay
  xftDraw: PXftDraw

  xftColorFg, xftColorHighlightFg: XftColor
  xftColorBg, xftColorHighlightBg: culong

#──────────────────────────────────────────────────────────────────────────────
#  Theme‑overlay timing state
#──────────────────────────────────────────────────────────────────────────────
const
  FadeDurationMs* = 500
  OverlayFontDelta = 2           ## overlay size = main − 2

var
  lastThemeSwitchMs*: int64 = 0
  currentThemeName*: string = ""

## Return current time in milliseconds since Unix epoch.
proc nowMs*(): int64 =
  (epochTime() * 1_000).int64

## Update overlay timing when the active theme changes.
proc notifyThemeChanged*(name: string) =
  currentThemeName = name
  lastThemeSwitchMs = nowMs()

#──────────────────────────────────────────────────────────────────────────────
#  Font helpers
#──────────────────────────────────────────────────────────────────────────────
proc deriveSmallerFont(base: string): string =
  ## Derive a slightly smaller variant from *base* by decreasing `:size=`.
  const key = ":size="
  let idx = base.find(key)
  if idx >= 0:
    let sizeStr = base[idx + key.len .. ^1]
    if sizeStr.len > 0 and sizeStr.allCharsInSet({'0' .. '9'}):
      let newSize = max(parseInt(sizeStr) - OverlayFontDelta, 6)
      return base[0 .. idx + key.len - 1] & $newSize
  result = base & ":size=9"

proc loadFont(display: PDisplay, screen: cint, name: string): PXftFont =
  ## Wrapper that quits with a helpful message on failure.
  let f = XftFontOpenName(display, screen, name)
  if f.isNil:
    quit "Failed to load font: " & name
  f

## Allocate X pixels & Xft colours from current config.
proc updateGuiColors*() =
  allocXftColor(config.fgColorHex, xftColorFg)
  allocXftColor(config.highlightFgColorHex, xftColorHighlightFg)
  xftColorBg         = config.bgColor
  xftColorHighlightBg = config.highlightBgColor

proc textWidth(txt: string; useOverlayFont = false): cint =
  ## Return pixel width of *txt* using the primary or overlay font.
  var ext: XGlyphInfo
  let pStr  = cast[PFcChar8](txt.cstring)
  let pExt  = cast[PXGlyphInfo](addr ext)

  if useOverlayFont:
    XftTextExtents8(display, overlayFont, pStr, cint(txt.len), pExt)
  else:
    XftTextExtents8(display, font,        pStr, cint(txt.len), pExt)

  return ext.xOff


#──────────────────────────────────────────────────────────────────────────────
#  Theme‑overlay (name fade‑in/out in top‑right corner)
#──────────────────────────────────────────────────────────────────────────────
proc drawThemeOverlay() =
  ## Draw the active theme name with a brief fade‑out in the top‑right corner.
  if currentThemeName.len == 0: return
  let elapsed = nowMs() - lastThemeSwitchMs
  if elapsed > FadeDurationMs: return

  # Linear alpha (1 → 0)
  let alpha = 1.0 - (elapsed.float / FadeDurationMs.float)

  # Semi‑transparent colour
  var col: XftColor
  col.color.red   = uint16((config.fgColor shr 16) and 0xFF) * 257
  col.color.green = uint16((config.fgColor shr  8) and 0xFF) * 257
  col.color.blue  = uint16((config.fgColor)        and 0xFF) * 257
  col.color.alpha = uint16(alpha * 65535)
  col.pixel       = config.fgColor

  # Position (top‑right, small margin)
  const marginX = 8
  const marginY = 6
  let tx = (config.winWidth - marginX - textWidth(currentThemeName, true)).cint
  let ty = (marginY + overlayFont.ascent).cint

  XftDrawStringUtf8(
    xftDraw,
    cast[PXftColor](addr col),                # ptr → PXftColor
    overlayFont,
    tx, ty,                                   # cint coords
    cast[PFcChar8](currentThemeName[0].addr), # precise PFcChar8 pointer
    currentThemeName.len.cint
  )

#──────────────────────────────────────────────────────────────────────────────
#  Initialisation
#──────────────────────────────────────────────────────────────────────────────
## Initialise X11 window, fonts, and colour resources.
proc initGui*() =
  display = XOpenDisplay(nil)
  if display.isNil: quit "Cannot open X display"
  screen = XDefaultScreen(display)
  # Fonts ----------------------------------------------------------------
  font         = loadFont(display, screen, config.fontName)
  overlayFont  = loadFont(display, screen, deriveSmallerFont(config.fontName))

  # Colours --------------------------------------------------------------
  config.bgColor         = parseColor(config.bgColorHex)
  config.fgColor         = parseColor(config.fgColorHex)
  config.highlightBgColor = parseColor(config.highlightBgColorHex)
  config.highlightFgColor = parseColor(config.highlightFgColorHex)
  config.borderColor     = parseColor(config.borderColorHex)
  updateGuiColors()

  # Window geometry ------------------------------------------------------
  var winX, winY: cint
  if config.centerWindow:
    let sw = XDisplayWidth(display, screen)
    let sh = XDisplayHeight(display, screen)
    winX = cint((sw - config.winWidth) div 2)
    case config.verticalAlign
    of "top":      winY = 50
    of "center":   winY = cint((sh - config.winMaxHeight) div 2)
    else:          winY = cint(sh div 3)                # "one‑third"
  else:
    winX = cint(config.positionX)
    winY = cint(config.positionY)

  var attrs: XSetWindowAttributes
  attrs.override_redirect = 1
  attrs.background_pixel  = config.bgColor
  attrs.border_pixel      = config.borderColor

  let valueMask = culong(CWOverrideRedirect or CWBackPixel or CWBorderPixel)

  window = XCreateWindow(
    display,
    XRootWindow(display, screen),
    winX, winY,
    cuint(config.winWidth),
    cuint(config.winMaxHeight),
    cuint(config.borderWidth),
    DefaultDepth(display, screen).cint,   # depth → cint
    cuint(InputOutput),                   # class → cuint
    DefaultVisual(display, screen),
    valueMask,                            # valuemask → culong
    cast[PXSetWindowAttributes](addr attrs)
  )

  discard XStoreName(display, window, "nim_launcher")
  discard XSelectInput(display, window,
               ExposureMask or KeyPressMask or KeyReleaseMask or
               FocusChangeMask or StructureNotifyMask)
  discard XMapWindow(display, window)
  discard XFlush(display)

  # Give our window the keyboard focus so we’ll see FocusOut when it blurs
  discard XSetInputFocus(
    display,
    window,
    RevertToParent,
    CurrentTime
  )

  gc      = XCreateGC(display, window, 0, nil)
  xftDraw = XftDrawCreate(display, window,
                          DefaultVisual(display, screen),
                          DefaultColormap(display, screen))

## Render *txt* at (x, y). Set `highlight = true` for selected row.
proc drawText*(txt: string; x, y: cint; highlight = false) =
  let fgCol = if highlight: xftColorHighlightFg else: xftColorFg
  let bgCol = if highlight: xftColorHighlightBg else: xftColorBg

  discard XSetForeground(display, gc, bgCol)
  discard XFillRectangle(display, window, gc,
                         x, y - font.ascent,
                         cuint(config.winWidth), cuint(config.lineHeight))

  XftDrawChange(xftDraw, window)
  XftDrawString8(
    xftDraw,
    cast[PXftColor](addr fgCol),   # colour  → PXftColor
    font,
    x, y,
    cast[PFcChar8](txt[0].addr),   # text ptr → PFcChar8
    txt.len.cint
  )

#──────────────────────────────────────────────────────────────────────────────
#  Main repaint entry
#──────────────────────────────────────────────────────────────────────────────
## Repaint entire launcher window including border.
proc redrawWindow*() =
  # Background -----------------------------------------------------------
  discard XSetForeground(display, gc, config.bgColor)
  discard XFillRectangle(
    display, window, gc, 0, 0,
    cuint(config.winWidth), cuint(config.winMaxHeight)
  )

  # Prompt ---------------------------------------------------------------
  var y: cint = font.ascent + 8
  let promptLine = config.prompt & inputText & (if benchMode: "" else: config.cursor)
  drawText(promptLine, 12, y)
  y += config.lineHeight.cint + 6       # advance for app rows

  # Rows -----------------------------------------------------------------
  for idx, app in filteredApps:
    if y > config.winMaxHeight: break
    let highlight = (idx == selectedIndex)
    drawText(app.name, 12, y, highlight)
    y += config.lineHeight.cint

  # Theme overlay --------------------------------------------------------
  drawThemeOverlay()

  # ── Border LAST so nothing over‑paints it ─────────────────────────────
  if config.borderWidth > 0:
    discard XSetForeground(display, gc, config.borderColor)
    for i in 0 ..< config.borderWidth:
      discard XDrawRectangle(
        display, window, gc,
        i.cint, i.cint,
        cuint(config.winWidth  - 1 - i * 2),
        cuint(config.winMaxHeight - 1 - i * 2)
      )

  discard XFlush(display)


