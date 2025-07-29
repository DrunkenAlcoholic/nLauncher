# Nim Launcher

> A lightning‑fast, X11‑native application + command launcher written in pure Nim.
> Inspired by Rofi and Tofi, designed for minimal latency, easy theming, and zero toolkit bloat.

![Nim Launcher screenshot](Screenshot.gif)

---

## Highlights

| Feature                            | Notes                                                                                    |
| ---------------------------------- | ---------------------------------------------------------------------------------------- |
| **Typo‑tolerant fuzzy search**     | `firefx` → Firefox                                                                       |
|  **Sub‑1 ms startup (bench mode)** | `--bench` flag for raw launch timing                                                     |
| **Recent‑apps history**            | Empty query shows your last launches first                                               |
| **100 % keyboard‑driven**          | Arrow keys / Enter / Esc                                                                 |
| **Live theme cycling**             | Press <kbd>F5</kbd> to rotate through built‑ins                                          |
| **Fully themable**                 | 25+ colour schemes shipped; define your own                                              |
| **Any Xft font**                   | `fontname = JetBrainsMono:size=14`                                                       |
| **Slash triggers**                 | `/ …` run command • `/c cfg` open dotfile • `/y video` or `/g query` open browser search |
| **Zero toolkit**                   | Pure Xlib + Xft ⇒ tiny binary                                                            |

---

## Building & Running

> **Skip this if you just use the pre‑built binary** in the repo release page.

### Dependencies

| Package      | Arch / Manjaro                 | Debian / Ubuntu                          |
| ------------ | ------------------------------ | ---------------------------------------- |
| Nim compiler | `sudo pacman -S nim`           | `sudo apt install nim`                   |
| X11 headers  | `sudo pacman -S libx11 libxft` | `sudo apt install libx11-dev libxft-dev` |

### Build

```bash
git clone https://github.com/DrunkenAlcoholic/nLauncher.git
cd nLauncher
nimble install x11            # one‑time; pulls Nim X11 bindings
nimble build -d:release       # creates ./nLauncher
```

### Bind to a hotkey

Example (i3 WM):

```ini
bindsym $mod+d exec --no-startup-id nLauncher
```

---

## Usage Cheat‑sheet

| Keys / Action       | Result                                           |
| ------------------- | ------------------------------------------------ |
| _Type letters_      | Instant fuzzy filter (typo tolerant)             |
| `/cmd …`            | Run shell command inside your terminal           |
| `/c …`              | Search `~/.config` for dotfiles → open in editor |
| `/y …`              | YouTube search in browser                        |
| `/g …`              | Google search in browser                         |
| **Enter**           | Launch item / run command                        |
| **Esc** / focus‑out | Quit                                             |
| **↑ / ↓**           | Navigate list                                    |
| **F5**              | Cycle built‑in themes                            |
| _(empty query)_     | Shows recent applications first                  |

Bench start‐time:

```bash
nLauncher --bench      # prints time & exits, also used to close window for hyperfine
```

---

## Configuration (`~/.config/nLauncher/config.ini`)

<details>
<summary>Click to expand</summary>

### `[window]`

| Key                 | Default     | Meaning                          |
| ------------------- | ----------- | -------------------------------- |
| `width`             | `600`       | Window width (px)                |
| `max_visible_items` | `15`        | Rows shown before scrolling      |
| `center`            | `true`      | Center horizontally              |
| `vertical_align`    | `one-third` | `top` \| `center` \| `one-third` |
| `position_x / y`    | `500 / 50`  | Used when `center = false`       |

### `[font]`

| Key        | Example                 |
| ---------- | ----------------------- |
| `fontname` | `JetBrainsMono:size=14` |

### `[input]`

| Prompt | Cursor |
| ------ | ------ |
| `> `   | `_`    |

### `[border]`

| Key     | Default |
| ------- | ------- |
| `width` | `2`     |

### `[colors]`

Same keys as other launchers (`background`, `foreground`, `highlight_background`, `highlight_foreground`, `border_color`). Hex `#RRGGBB`.

### `[theme]`

```ini
[theme]
name = Nord
```

Leave blank to honour `[colors]`.

### `[terminal]`

```ini
[terminal]
program = alacritty
```

If empty, `$TERMINAL` env or a fallback list (`kitty`, `wezterm`, `xterm`…) is used.

</details>

---

## Built‑in Themes

Nord • Dracula • Solarized (Light + Dark) • Gruvbox (Light + Dark) • Catppuccin (4 flavours) • Material (Light + Dark) • One (Light + Dark) • Monokai (+ Pro) • GitHub (Light + Dark) • Ayu (Light + Dark) • Synthwave 84 • Palenight • Cobalt • Tokyo Night (Light + Dark)

Cycle live with <kbd>F5</kbd>.

---

## Planned

- Pixel‑level character highlighting in matches
- Optional application icons (SVG/PNG lookup with caching)
- Config‑selectable history length
- Wayland port (via `wlroots` or `wlr-layer-shell`) 🤔

---

## Credits

_Written & maintained by @DrunkenAlcoholic._
ChatGPT assisted in refactors, edge‑case handling, and this README.

Licensed under **MIT**.
Enjoy launching at ludicrous speed 🚀
