import
  x11/xlib,
  x11/xutil,
  x11/x,
  x11/keysym # NEW: Import key symbol definitions

# --- Configuration ---
const
  windowWidth = 600
  windowHeight = 400
  windowX = 500
  windowY = 50

# --- Global Variables ---
var
  display: PDisplay
  window: Window
  graphicsContext: GC

proc init() =
  display = XOpenDisplay(nil)
  if display == nil:
    quit "Failed to open display"

  let screen = XDefaultScreen(display)
  let rootWindow = XRootWindow(display, screen)

  var attributes: XSetWindowAttributes
  attributes.override_redirect = true.XBool
  attributes.background_pixel = XWhitePixel(display, screen)
  attributes.event_mask = KeyPressMask or ExposureMask

  let valuemask: culong = CWOverrideRedirect or CWBackPixel or CWEventMask

  window = XCreateWindow(display, rootWindow, windowX, windowY, windowWidth,
      windowHeight, 0, CopyFromParent, InputOutput, nil,
      valuemask, attributes.addr)

  graphicsContext = XDefaultGC(display, screen)
  discard XSetForeground(display, graphicsContext, XBlackPixel(display, screen))

  discard XMapWindow(display, window)

  # NEW: Programmatically set the input focus to our window.
  discard XSetInputFocus(display, window, RevertToParent, CurrentTime)

  discard XFlush(display)

proc drawText(text: string, x, y: int) =
  discard XDrawString(display, window, graphicsContext,
                      cint(x), cint(y), cstring(text), cint(text.len))

proc redrawWindow() =
  echo "Redrawing window..."
  drawText("This is our launcher window!", 20, 30)
  drawText("Press the ESC key to close.", 20, 60) # Updated instructions

proc mainLoop() =
  var event: XEvent
  while true:
    discard XNextEvent(display, event.addr)
    case event.theType
    of Expose:
      redrawWindow()
    of KeyPress:
      # NEW: Check for the specific key that was pressed.
      let keysym = XLookupKeysym(cast[PXKeyEvent](event.addr), 0)
      if keysym == XK_Escape:
        echo "Escape key pressed. Exiting."
        break # Exit the loop
    else:
      discard

proc main() =
  init()
  mainLoop()
  discard XDestroyWindow(display, window)
  discard XCloseDisplay(display)

main()
