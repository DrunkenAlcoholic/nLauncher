# Nim Launcher

> A simple, fast, and highly configurable application launcher for Linux (X11) written in pure Nim. Inspired by Rofi, designed for personal use and customization.

![Nim Launcher with Dracula Colours](ScreenShot.png)

## Features

- **Fuzzy Search:** Instantly filters applications as you type.
- **Keyboard Navigation:** Fully controllable with the keyboard (arrow keys, Enter, Escape).
- **Borderless & Centered:** Appears as a clean, undecorated window in the center of your screen.
- **Extremely Fast Startup:** Uses an intelligent cache that only re-scans for applications when they actually change.
- **Highly Configurable:** Almost every aspect of the look and feel can be customized via a simple INI file.
- **Built-in Themes:** Choose from popular color schemes like Nord, Dracula, Solarized, Gruvbox, Catppuccin, and more.
- **Lightweight:** No heavy GUI toolkit dependencies—just a direct interface with X11.

## Getting Started

Follow these steps to build and run the launcher on your system.

### Prerequisites

You will need Nim compiler and X11 development libraries only if you want to build from source.

1. **Install Nim:** Follow the official instructions at [nim-lang.org](https://nim-lang.org/install.html).

2. **Install X11 Development Libraries:**
   - **Arch / Manjaro / CachyOS:**
     ```bash
     sudo pacman -S libx11
     ```
   - **Debian / Ubuntu / Pop!\_OS:**
     ```bash
     sudo apt-get install libx11-dev
     ```
   - **Fedora / CentOS:**
     ```bash
     sudo dnf install libX11-devel
     ```

### Build or Run

- You can **run the precompiled binary** included in the repository root (if available).
- Or **build from source** by cloning the repo and compiling:

```bash
git clone https://github.com/DrunkenAlcoholic/nim_launcher.git
cd nim_launcher
nimble install x11
nimble build -d:release
```

This produces a nim_launcher executable you can move to your $PATH for easy access.

## How to Use

### Launching

This program is designed to be launched via a hotkey managed by your Window Manager (like i3, Sway, bspwm) or Desktop Environment (like GNOME, KDE).

For example, in i3 you would add this to your config file:
`bindsym $mod+d exec /path/to/your/nim_launcher`

### Controls

The launcher is controlled entirely with the keyboard:

- **Start Typing:** Begin typing to fuzzy search for an application.
- **Up/Down Arrows:** Navigate the list of results.
- **Enter:** Launch the selected application.
- **Escape:** Close the launcher immediately.
- **Clicking Away:** If you click on another window, the launcher will automatically close (as it has lost focus).

## Configuration

On the first run, the launcher will automatically create a default configuration file at:
`~/.config/nim_launcher/config.ini`

You can edit this file to customize nearly every aspect of the launcher.

---

### `config.ini` Options

#### `[window]`

| Key                 | Description                                                                                                  | Example       |
| ------------------- | ------------------------------------------------------------------------------------------------------------ | ------------- |
| `width`             | The width of the launcher window in pixels.                                                                  | `600`         |
| `max_visible_items` | The maximum number of application names to show at once. The window height is calculated from this value.    | `15`          |
| `center`            | If `true`, the window will be centered on the screen. If `false`, it will use `position_x` and `position_y`. | `true`        |
| `position_x`        | The X coordinate for the window's top-left corner if `center` is `false`.                                    | `500`         |
| `position_y`        | The Y coordinate for the window's top-left corner if `center` is `false`.                                    | `50`          |
| `vertical_align`    | Controls the vertical position when centered. Can be `"top"`, `"center"`, or `"one-third"`.                  | `"one-third"` |

#### `[colors]`

All colors must be in 7-character hexadecimal format (e.g., `#RRGGBB`).

| Key                    | Description                                | Example     |
| ---------------------- | ------------------------------------------ | ----------- |
| `background`           | The main background color of the window.   | `"#2E3440"` |
| `foreground`           | The color of the text.                     | `"#D8DEE9"` |
| `highlight_background` | The background color of the selected item. | `"#88C0D0"` |
| `highlight_foreground` | The text color of the selected item.       | `"#2E3440"` |
| `border_color`         | The color of the window border.            | `"#4C566A"` |

#### `[border]`

| Key     | Description                                                      | Example |
| ------- | ---------------------------------------------------------------- | ------- |
| `width` | The width of the window border in pixels. Set to `0` to disable. | `2`     |

#### `[input]`

| Key      | Description                                  | Example |
| -------- | -------------------------------------------- | ------- |
| `prompt` | The text that appears before your input.     | `"> "`  |
| `cursor` | The character that appears after your input. | `"_"`   |

#### `[theme]`

| Key    | Description                                                                                                      | Example                 |
| ------ | ---------------------------------------------------------------------------------------------------------------- | ----------------------- |
| `name` | Set this to the name of a built-in theme to override the colors in `[colors]`. Leave empty to use custom colors. | `"Nord"` or `"Dracula"` |

---

## Built-in Themes

The launcher supports these popular themes out of the box:

- **Nord**
- **Solarized Dark**
- **Solarized Light**
- **Gruvbox Dark**
- **Gruvbox Light**
- **Dracula**
- **Monokai**
- **One Dark**
- **Material Dark**
- **Material Light**
- **Cobalt**
- **Ayu Dark**
- **Ayu Light**
- **Catppuccin Mocha**
- **Catppuccin Latte**
- **Catppuccin Frappe**

---

## Future Plans

This project is functionally complete, but here are some ideas for future improvements:

- **Font Rendering:** Use a library like `Xft` to allow for custom TTF fonts and sizes.
- **Icon Support:** Display application icons next to their names.
- **Advanced Fuzzy Search:** Implement a more powerful algorithm that can handle typos.

## License

This project is licensed under the GPL-3 License. See the `LICENSE` file for details.
