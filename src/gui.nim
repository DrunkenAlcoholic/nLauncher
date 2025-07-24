# scr/gui.nim
#
# Handles all X11 window creation, event handling, and drawing for the launcher.

import strutils
import x11/[xlib, x]
import state

# --- Color Handling ---

proc parseColor*(hex: string): culong =
  ## Converts a user-friendly hex color string (e.g., "#RRGGBB") into a pixel
  ## value that the X11 server can understand.
  var r, g, b: int
  if hex.startsWith("#") and hex.len == 7:
    try:
      # Use the standard library to parse the R, G, and B hex components.
      r = parseHexInt(hex[1..2])
      g = parseHexInt(hex[3..4])
      b = parseHexInt(hex[5..6])
    except ValueError:
      echo "Warning: Invalid hex character in color string: ", hex
      return 0 # Default to black on error
  else:
    echo "Warning: Invalid hex color format: ", hex
    return 0 # Default to black on error

  var color: XColor
  # X11 requires colors in a 16-bit range (0-65535), not 8-bit (0-255).
  # We scale the values by multiplying by 257 (since 65535 / 255 = 257).
  color.red = uint16(r * 257)
  color.green = uint16(g * 257)
  color.blue = uint16(b * 257)
  color.flags = cast[cchar](DoRed or DoGreen or DoBlue)

  # Ask the X server to allocate our desired color in its colormap.
  if XAllocColor(display, XDefaultColormap(display, screen), color.addr) == 0:
    echo "Warning: Failed to allocate color: ", hex
    return 0
  
  return color.pixel

# --- Window Initialization and Management ---

proc initGui*() =
  ## Connects to the X server and creates the main launcher window.
  
  # 1. Connect to the X server and get the default screen.
  display = XOpenDisplay(nil)
  if display == nil: quit "Failed to open display"
  screen = XDefaultScreen(display)

  # 2. Parse all color strings from the config into usable X11 pixel values.
  config.bgColor = parseColor(config.bgColorHex)
  config.fgColor = parseColor(config.fgColorHex)
  config.highlightBgColor = parseColor(config.highlightBgColorHex)
  config.highlightFgColor = parseColor(config.highlightFgColorHex)
  config.borderColor = parseColor(config.borderColorHex)

  # 3. Calculate the final window position based on the config.
  var finalX, finalY: cint
  if config.centerWindow:
    let screenWidth = XDisplayWidth(display, screen)
    let screenHeight = XDisplayHeight(display, screen)
    finalX = cint((screenWidth - config.winWidth) / 2)
    case config.verticalAlign
    of "top": finalY = cint(50)
    of "center": finalY = cint((screenHeight - config.winMaxHeight) / 2)
    else: finalY = cint((screenHeight - config.winMaxHeight) / 3) # Default
  else:
    finalX = cint(config.positionX)
    finalY = cint(config.positionY)

  # 4. Set the window's attributes. This is where we make it borderless.
  var attributes: XSetWindowAttributes
  # This crucial flag tells the window manager to completely ignore our window,
  # preventing it from adding a title bar, borders, or shadows.
  attributes.override_redirect = true.XBool
  attributes.background_pixel = config.bgColor
  # Specify which events we want to listen for.
  attributes.event_mask = KeyPressMask or ExposureMask or FocusChangeMask
  let valuemask: culong = CWOverrideRedirect or CWBackPixel or CWEventMask

  # 5. Create the window with our specified attributes.
  window = XCreateWindow(display, XRootWindow(display, screen), finalX, finalY,
    cuint(config.winWidth), cuint(config.winMaxHeight), 0, CopyFromParent, InputOutput, nil,
    valuemask, attributes.addr)
  
  # 6. Get the default Graphics Context, which holds drawing info like colors.
  graphicsContext = XDefaultGC(display, screen)

  # 7. Make the window visible and request keyboard focus.
  discard XMapWindow(display, window)
  discard XSetInputFocus(display, window, RevertToParent, CurrentTime)
  discard XFlush(display) # Send all commands to the X server now.

# --- Drawing Procedures ---

proc drawText*(text: string, x, y: int, isSelected: bool) =
  ## Draws a string of text onto the window at the given coordinates.
  let (fg, bg) =
    if isSelected: (config.highlightFgColor, config.highlightBgColor)
    else: (config.fgColor, config.bgColor)
  
  discard XSetForeground(display, graphicsContext, fg)
  discard XSetBackground(display, graphicsContext, bg)
  
  # The X11 C library requires specific C-types, so we must cast our Nim types.
  discard XDrawString(display, window, graphicsContext,
                      cint(x), cint(y), cstring(text), cint(text.len))

proc redrawWindow*() =
  ## Redraws the entire contents of the launcher window based on the current state.
  discard XClearWindow(display, window)

  # 1. Draw the window border (if configured).
  if config.borderWidth > 0:
    discard XSetForeground(display, graphicsContext, config.borderColor)
    # Draw multiple rectangles to create a thick border.
    for i in 0 ..< config.borderWidth:
      discard XDrawRectangle(display, window, graphicsContext,
        cint(i), cint(i),
        cuint(config.winWidth - 1 - (i*2)), cuint(config.winMaxHeight - 1 - (i*2)))

  # 2. Draw the user input field.
  drawText(config.prompt & inputText & config.cursor, 20, 30, isSelected = false)

  # 3. Draw the visible portion of the application list.
  let listStartY = 50
  for i in 0 ..< config.maxVisibleItems:
    # Calculate the actual index in the filtered list based on our "camera"
    let itemIndex = viewOffset + i
    if itemIndex >= filteredApps.len: break # Stop if we run out of apps to show

    let app = filteredApps[itemIndex]
    let yPos = listStartY + (i * config.lineHeight)
    let isSelected = (itemIndex == selectedIndex)

    # If this item is the selected one, draw a highlight rectangle first.
    if isSelected:
      discard XSetForeground(display, graphicsContext, config.highlightBgColor)
      discard XFillRectangle(display, window, graphicsContext,
        cint(10), cint(yPos - config.lineHeight + 5),
        cuint(config.winWidth - 20), cuint(config.lineHeight))
    
    # Draw the application name.
    drawText(app.name, 20, yPos, isSelected = isSelected)
  
  # 4. Flush the drawing buffer to ensure everything appears on screen.
  discard XFlush(display)
