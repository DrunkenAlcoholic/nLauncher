# src/gui.nim
import strutils
import x11/[xlib, x]
import state

proc parseColor*(hex: string): culong =
  # (This is the exact same code as before)
  var r, g, b: int
  if hex.startsWith("#") and hex.len == 7:
    try: r = parseHexInt(hex[1..2]); g = parseHexInt(hex[3..4]); b = parseHexInt(hex[5..6])
    except ValueError: echo "Warning: Invalid hex character in color string: ", hex; return 0
  else: echo "Warning: Invalid hex color format: ", hex; return 0
  var color: XColor
  color.red = uint16(r * 257); color.green = uint16(g * 257); color.blue = uint16(b * 257)
  color.flags = cast[cchar](DoRed or DoGreen or DoBlue)
  if XAllocColor(display, XDefaultColormap(display, screen), color.addr) == 0:
    echo "Warning: Failed to allocate color: ", hex; return 0
  return color.pixel

proc initGui*() =
  # (This is the exact same code as before)
  display = XOpenDisplay(nil)
  if display == nil: quit "Failed to open display"
  screen = XDefaultScreen(display)
  config.bgColor = parseColor(config.bgColorHex)
  config.fgColor = parseColor(config.fgColorHex)
  config.highlightBgColor = parseColor(config.highlightBgColorHex)
  config.highlightFgColor = parseColor(config.highlightFgColorHex)
  config.borderColor = parseColor(config.borderColorHex)
  var finalX, finalY: cint
  if config.centerWindow:
    let screenWidth = XDisplayWidth(display, screen)
    let screenHeight = XDisplayHeight(display, screen)
    finalX = cint((screenWidth - config.winWidth) / 2)
    case config.verticalAlign
    of "top": finalY = cint(50)
    of "center": finalY = cint((screenHeight - config.winMaxHeight) / 2)
    else: finalY = cint((screenHeight - config.winMaxHeight) / 3)
  else:
    finalX = cint(config.positionX)
    finalY = cint(config.positionY)
  var attributes: XSetWindowAttributes
  attributes.override_redirect = true.XBool
  attributes.background_pixel = config.bgColor
  attributes.event_mask = KeyPressMask or ExposureMask or FocusChangeMask
  let valuemask: culong = CWOverrideRedirect or CWBackPixel or CWEventMask
  window = XCreateWindow(display, XRootWindow(display, screen), finalX, finalY,
    cuint(config.winWidth), cuint(config.winMaxHeight), 0, CopyFromParent, InputOutput, nil,
    valuemask, attributes.addr)
  graphicsContext = XDefaultGC(display, screen)
  discard XMapWindow(display, window)
  discard XSetInputFocus(display, window, RevertToParent, CurrentTime)
  discard XFlush(display)

proc drawText*(text: string, x, y: int, isSelected: bool) =
  # (This is the exact same code as before)
  let (fg, bg) =
    if isSelected: (config.highlightFgColor, config.highlightBgColor)
    else: (config.fgColor, config.bgColor)
  discard XSetForeground(display, graphicsContext, fg)
  discard XSetBackground(display, graphicsContext, bg)
  discard XDrawString(display, window, graphicsContext,
                      cint(x), cint(y), cstring(text), cint(text.len))

proc redrawWindow*() =
  # (This is the exact same code as before)
  discard XClearWindow(display, window)
  if config.borderWidth > 0:
    discard XSetForeground(display, graphicsContext, config.borderColor)
    for i in 0 ..< config.borderWidth:
      discard XDrawRectangle(display, window, graphicsContext,
        cint(i), cint(i),
        cuint(config.winWidth - 1 - (i*2)), cuint(config.winMaxHeight - 1 - (i*2)))
  drawText(config.prompt & inputText & config.cursor, 20, 30, isSelected = false)
  let listStartY = 50
  for i in 0 ..< config.maxVisibleItems:
    let itemIndex = viewOffset + i
    if itemIndex >= filteredApps.len: break
    let app = filteredApps[itemIndex]
    let yPos = listStartY + (i * config.lineHeight)
    let isSelected = (itemIndex == selectedIndex)
    if isSelected:
      discard XSetForeground(display, graphicsContext, config.highlightBgColor)
      discard XFillRectangle(display, window, graphicsContext,
        cint(10), cint(yPos - config.lineHeight + 5),
        cuint(config.winWidth - 20), cuint(config.lineHeight))
    drawText(app.name, 20, yPos, isSelected = isSelected)
  discard XFlush(display)
