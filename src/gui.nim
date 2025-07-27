# src/gui.nim
#
# Handles all X11 window creation, event handling, and drawing for the launcher.

import strutils
import x11/[xlib, xft, x, xrender]
import state

# --- Xft and Xlib Color Variables ---
var font: PXftFont
var xftDraw: PXftDraw
var xftColorFg, xftColorHighlightFg: XftColor
var xftColorBg, xftColorHighlightBg: culong

# --- Color Handling ---

proc parseColor*(hex: string): culong =
  ## Converts a hex string like "#RRGGBB" to a pixel value for Xlib.
  var r, g, b: int
  if hex.startsWith("#") and hex.len == 7:
    try:
      r = parseHexInt(hex[1 .. 2])
      g = parseHexInt(hex[3 .. 4])
      b = parseHexInt(hex[5 .. 6])
    except ValueError:
      echo "Warning: Invalid hex character in color string: ", hex
      return 0
  else:
    echo "Warning: Invalid hex color format: ", hex
    return 0

  var color: XColor
  color.red = uint16(r * 257)
  color.green = uint16(g * 257)
  color.blue = uint16(b * 257)
  color.flags = cast[cchar](DoRed or DoGreen or DoBlue)

  if XAllocColor(display, XDefaultColormap(display, screen), color.addr) == 0:
    echo "Warning: Failed to allocate color: ", hex
    return 0

  return color.pixel

proc allocXftColor(hex: string, colorRef: var XftColor) =
  ## Allocates a font color using XftColor + XRenderColor.
  var r, g, b: int
  if hex.startsWith("#") and hex.len == 7:
    try:
      r = parseHexInt(hex[1 .. 2])
      g = parseHexInt(hex[3 .. 4])
      b = parseHexInt(hex[5 .. 6])
    except ValueError:
      quit "Invalid color hex: " & hex
  else:
    quit "Invalid hex color format: " & hex

  var xrenderColor: XRenderColor
  xrenderColor.red = uint16(r * 257)
  xrenderColor.green = uint16(g * 257)
  xrenderColor.blue = uint16(b * 257)
  xrenderColor.alpha = 65535

  if XftColorAllocValue(
    display,
    DefaultVisual(display, screen),
    DefaultColormap(display, screen),
    addr xrenderColor,
    addr colorRef,
  ) == 0:
    quit "Failed to allocate XftColor for: " & hex

proc updateGuiColors*() =
  ## Updates all Xft and Xlib color variables after a theme change.
  allocXftColor(config.fgColorHex, xftColorFg)
  allocXftColor(config.highlightFgColorHex, xftColorHighlightFg)
  xftColorBg = config.bgColor
  xftColorHighlightBg = config.highlightBgColor

proc loadFont(display: PDisplay, screen: cint, fontName: string): PXftFont =
  ## Loads the specified font using Xft.
  let f = XftFontOpenName(display, screen, fontName)
  if f.isNil:
    quit "Failed to load font: " & fontName
  return f

# --- Window Initialization and Management ---

proc initGui*() =
  ## Connects to the X server and creates the main launcher window.
  display = XOpenDisplay(nil)
  if display == nil:
    quit "Failed to open display"
  screen = XDefaultScreen(display)

  font = loadFont(display, screen, config.fontName)

  # Parse colors for Xlib
  config.bgColor = parseColor(config.bgColorHex)
  config.fgColor = parseColor(config.fgColorHex)
  config.highlightBgColor = parseColor(config.highlightBgColorHex)
  config.highlightFgColor = parseColor(config.highlightFgColorHex)
  config.borderColor = parseColor(config.borderColorHex)

  # Calculate window position
  var finalX, finalY: cint
  if config.centerWindow:
    let screenWidth = XDisplayWidth(display, screen)
    let screenHeight = XDisplayHeight(display, screen)
    finalX = cint((screenWidth - config.winWidth) div 2)
    case config.verticalAlign
    of "top":
      finalY = 50
    of "center":
      finalY = cint((screenHeight - config.winMaxHeight) div 2)
    else:
      finalY = cint((screenHeight - config.winMaxHeight) div 3)
  else:
    finalX = cint(config.positionX)
    finalY = cint(config.positionY)

  var attributes: XSetWindowAttributes
  attributes.override_redirect = true.XBool
  attributes.background_pixel = config.bgColor
  attributes.event_mask = KeyPressMask or ExposureMask or FocusChangeMask
  let valuemask: culong = CWOverrideRedirect or CWBackPixel or CWEventMask

  window = XCreateWindow(
    display,
    XRootWindow(display, screen),
    finalX,
    finalY,
    cuint(config.winWidth),
    cuint(config.winMaxHeight),
    0,
    CopyFromParent,
    InputOutput,
    nil,
    valuemask,
    addr attributes,
  )

  graphicsContext = XDefaultGC(display, screen)

  discard XMapWindow(display, window)
  discard XSetInputFocus(display, window, RevertToParent, CurrentTime)
  discard XFlush(display)

  # Initialize XftDraw (must be after XMapWindow)
  xftDraw = XftDrawCreate(
    display, window, DefaultVisual(display, screen), DefaultColormap(display, screen)
  )
  if xftDraw.isNil:
    quit "Failed to create XftDraw"

  # Allocate Xft colors for text
  allocXftColor(config.fgColorHex, xftColorFg)
  allocXftColor(config.highlightFgColorHex, xftColorHighlightFg)

  # Use raw Xlib color pixels for rectangle fills
  xftColorBg = config.bgColor
  xftColorHighlightBg = config.highlightBgColor

  echo "InitGUI Using font: ", config.fontName

# --- Drawing Procedures ---

proc drawText*(text: string, x, y: int, isSelected: bool) =
  ## Draws text using Xft at the given coordinates with font and highlight handling.
  if font.isNil or xftDraw.isNil:
    echo "Error: font or xftDraw is nil. Cannot draw text."
    return

  let fgColor = if isSelected: xftColorHighlightFg.addr else: xftColorFg.addr
  let bgColor = if isSelected: xftColorHighlightBg else: xftColorBg

  let ascent = font.ascent
  let descent = font.descent
  let totalHeight = ascent + descent
  let verticalOffset = (config.lineHeight - totalHeight) div 2

  let rectY = y - ascent - verticalOffset - 1
  let rectHeight = config.lineHeight + 2

  let marginX = max(6, config.borderWidth + 2)
  let marginW = config.winWidth - (marginX * 2)

  discard XSetForeground(display, graphicsContext, bgColor)
  discard XFillRectangle(
    display,
    window,
    graphicsContext,
    cint(marginX),
    cint(rectY),
    cuint(marginW),
    cuint(rectHeight),
  )

  XftDrawStringUtf8(
    xftDraw,
    fgColor,
    font,
    cint(x),
    cint(y),
    cast[ptr FcChar8](text[0].addr),
    cint(text.len),
  )

proc redrawWindow*() =
  ## Redraws the entire launcher window.
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

  if config.borderWidth > 0:
    discard XSetForeground(display, graphicsContext, config.borderColor)
    for i in 0 ..< config.borderWidth:
      discard XDrawRectangle(
        display,
        window,
        graphicsContext,
        cint(i),
        cint(i),
        cuint(config.winWidth - 1 - (i * 2)),
        cuint(config.winMaxHeight - 1 - (i * 2)),
      )

  drawText(config.prompt & inputText & config.cursor, 20, 30, isSelected = false)

  let listStartY = 30 + config.lineHeight

  for i in 0 ..< config.maxVisibleItems:
    let itemIndex = viewOffset + i
    if itemIndex >= filteredApps.len:
      break

    let app = filteredApps[itemIndex]
    let yPos = listStartY + (i * config.lineHeight)
    let isSelected = (itemIndex == selectedIndex)

    if isSelected:
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

    drawText(app.name, 20, yPos, isSelected)

  discard XFlush(display)
