# src/gui.nim
## gui.nim — X11 / Xft drawing and window management
## MIT; see LICENSE for details.

# ── Imports ─────────────────────────────────────────────────────────────
import std/[strutils, times, os]
import x11/[xlib, xft, x, xrender]
import ./[state, utils]          # display*, screen*, window*, gc*, config …

# ── Global Xft handles ─────────────────────────────────────────────────────
var
  font*: PXftFont                ## primary UI font (config.fontName)
  overlayFont*: PXftFont         ## smaller font for theme‑name overlay
  xftDraw: PXftDraw

  xftColorFg, xftColorHighlightFg: XftColor
  xftColorBg, xftColorHighlightBg: culong

# ── Overlay timing state ─────────────────────────────────────────────────
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

# ── Font helpers ─────────────────────────────────────────────────────────
## deriveSmallerFont returns a font string 2pt smaller than base.
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

# ── Initialization ───────────────────────────────────────────────────────
## initGui creates the X11 window, loads fonts, sets up colours.
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
  timeIt "UpdateGuiColors" :
    updateGuiColors()

  timeIt "Create Window" :
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

    # ── Set up window attributes ──────────────────────────────────────────
    var attrs: XSetWindowAttributes
    let isWayland = getEnv("WAYLAND_DISPLAY") != ""
    attrs.override_redirect = if isWayland: 0 else: 1
    attrs.background_pixel  = config.bgColor
    attrs.border_pixel      = config.borderColor

    # Build the valuemask (must be culong)
    let valueMask = culong(
      CWBackPixel or CWBorderPixel or
      (if not isWayland: CWOverrideRedirect else: 0)
    )

    # ── Create the window ─────────────────────────────────────────────────
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

    # ── Under Wayland/Xwayland: mark floating + remove decorations ────────
    if isWayland:
      # 1) _NET_WM_WINDOW_TYPE_DIALOG → floating
      let wmTypeAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE", 0)
      let dialogAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE_DIALOG", 0)
      let atomAtom   = XInternAtom(display, "ATOM", 0)
      discard XChangeProperty(
        display, window,
        wmTypeAtom, atomAtom,
        32.cint, PropModeReplace,
        cast[Pcuchar](addr dialogAtom), 1.cint
      )

      # 2) Motif hints → strip all decorations
      const MWM_HINTS_DECORATIONS = 2'u32
      let mwmHintsAtom = XInternAtom(display, "_MOTIF_WM_HINTS", 0)
      var mwmHints: array[5, uint64]
      mwmHints[0] = MWM_HINTS_DECORATIONS  # flags → we’re only touching decorations
      mwmHints[2] = 0'u64                 # decorations = 0 (none)
      discard XChangeProperty(
        display, window,
        mwmHintsAtom, mwmHintsAtom,
        32.cint, PropModeReplace,
        cast[Pcuchar](addr mwmHints), mwmHints.len.cint
      )

    # ── Common setup ────────────────────────────────────────────────────────
    discard XStoreName(display, window, "nLauncher")
    discard XSelectInput(
      display, window,
      ExposureMask or KeyPressMask or KeyReleaseMask or
      FocusChangeMask or StructureNotifyMask or ButtonPressMask
    )
    discard XMapWindow(display, window)
    discard XFlush(display)

    # Grab pointer so clicks anywhere send ButtonPress to us
    discard XGrabPointer(
      display,
      window,
      1,                        # ownerEvents?
      ButtonPressMask,             # event mask
      GrabModeAsync, GrabModeAsync,
      0, 0,                  # confine_to, cursor
      CurrentTime
    )

    # ── Focus handling ─────────────────────────────────────────────────────
    if not isWayland:
      discard XSetInputFocus(display, window, RevertToParent, CurrentTime)

    # ── Create graphics contexts ──────────────────────────────────────────
    gc      = XCreateGC(display, window, 0, nil)
    xftDraw = XftDrawCreate(
      display, window,
      DefaultVisual(display, screen),
      DefaultColormap(display, screen)
    )

# ── Drawing routines ─────────────────────────────────────────────────────
## drawText renders `txt` at (x, y); highlight = true uses highlight colours.
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


## redrawWindow clears and repaints all UI elements.
proc redrawWindow*() =
  # Background ─────────────────────────────────────────────────────────────
  discard XSetForeground(display, gc, config.bgColor)
  discard XFillRectangle(
    display, window, gc,
    0, 0,
    cuint(config.winWidth),
    cuint(config.winMaxHeight)
  )

  # Prompt ─────────────────────────────────────────────────────────────────
  var y: cint = font.ascent + 8
  let promptLine = config.prompt & inputText & (if benchMode: "" else: config.cursor)
  drawText(promptLine, 12, y)
  # add a small vertical gap before the list
  y += config.lineHeight.cint + 6

  # Rows (with scrolling) ──────────────────────────────────────────────────
  let total   = filteredApps.len
  let maxRows = config.maxVisibleItems
  let start   = viewOffset
  let finish  = min(viewOffset + maxRows, total)

  for idx in start ..< finish:
    let app       = filteredApps[idx]
    let highlight = (idx == selectedIndex)
    drawText(app.name, 12, y, highlight)
    y += config.lineHeight.cint

  # Theme overlay ────────────────────────────────────────────────────────────
  drawThemeOverlay()

  # Clock at bottom-right ─────────────────────────────────────────────────────
  let nowStr = now().format("HH:mm")
  let cw = textWidth(nowStr)
  let cx = config.winWidth - int(cw) - 2
  let cy = config.winMaxHeight - 8
  XftDrawStringUtf8(xftDraw, cast[PXftColor](addr xftColorFg), overlayFont,
    cint(cx), cint(cy),
    cast[PFcChar8](nowStr[0].addr), nowStr.len.cint
  )

  # Border (draw last so nothing over‑paints it) ─────────────────────────────
  if config.borderWidth > 0:
    discard XSetForeground(display, gc, config.borderColor)
    for i in 0 ..< config.borderWidth:
      discard XDrawRectangle(
        display, window, gc,
        i.cint, i.cint,
        cuint(config.winWidth  - 1 - i * 2),
        cuint(config.winMaxHeight - 1 - i * 2)
      )

  # Finally flush all drawing commands ────────────────────────────────────────
  discard XFlush(display)
