# nLauncher

> A lightning‑fast, X11‑native application and command launcher written in Nim.  
> Minimal dependencies, zero toolkit bloat, instant fuzzy search, and rich theming.

![nLauncher screenshot](Screenshot.gif)

---

## Highlights

| Feature                            | Notes                                                                                          |
| ---------------------------------- | ---------------------------------------------------------------------------------------------- |
| **Fast fuzzy search**     | `firefx` → “Firefox”                                                                           |
| **Live clock**                     | Small HH:mm clock in the bottom‑right                                                         |
| **Sub‑1 ms startup (bench mode)**  | `--bench` flag for raw launch timing                                                          |
| **Recent‑apps history**            | Empty query shows your last launches first                                                    |
| **100 % keyboard‑driven**          | Arrow keys / Enter / Esc                                                                      |
| **Live theme cycling & persistence** | Press F5 to cycle themes; saves your last choice in the TOML config                           |
| **Fully themable via TOML**        | 25+ colour schemes built‑in; add your own under [[themes]] in `nlauncher.toml`                 |
| **Slash triggers**                 | `/ …` run shell command • `/c …` open dotfile • `/y …` YouTube • `/g …` Google • `/w …` Wiki     |
| **Zero toolkit**                   | Pure Xlib + Xft + [parsetoml](https://github.com/pragmagic/parsetoml)                          |

---

## Building & Running

> **Skip this if you use the pre‑built binary** from the latest release.

### Dependencies

- **Nim**: install via the recommended [choosenim](https://nim-lang.org/choosenim) script:  
  ```bash
  curl https://nim-lang.org/choosenim/init.sh -sSf | sh
  ```
- **X11 headers** & **Xft**:  
  - Arch/Manjaro: `sudo pacman -S libx11 libxft`  
  - Debian/Ubuntu: `sudo apt install libx11-dev libxft-dev`
- **Nimble packages**:  
  ```bash
  nimble install parsetoml x11
  ```

### Build

```bash
git clone https://github.com/DrunkenAlcoholic/nLauncher.git
cd nLauncher
nimble release   # produces ./bin/nlauncher
```

### Command‑line flags

- `--bench` → prints millisecond‑precision startup timings and exits  

---

## Usage Cheat‑sheet

| Keys / Pattern      | Action                                                                   |
| ------------------- | ------------------------------------------------------------------------ |
| _Type letters_      | Instant fuzzy filter (typo‑tolerant)                                     |
| `/ …`               | Run shell command (everything after the slash is passed to your shell)  |
| `/c …`              | Search `~/.config` for dotfiles and open in your editor                  |
| `/y …`              | Search YouTube in browser                                                |
| `/g …`              | Google search in browser                                                 |
| `/w …`              | Wikipedia search in browser                                              |
| **Enter**           | Launch item / run command                                                |
| **Esc**             | Quit                                                                     |
| **↑ / ↓**           | Navigate list                                                            |
| **F5**              | Cycle built‑in themes                                                    |
| _(empty query)_     | Shows recent applications first                                          |

---

## Configuration

The first time you run `nlauncher`, it creates:

```
~/.config/nLauncher/nlauncher.toml
```

Copy & paste this skeleton or edit in place:

```toml
# nlauncher.toml

[window]
width               = 500                  # Width of the launcher window
max_visible_items   = 10                   # Number of rows visible at once
center              = true                # If true use `vertical_align`; false uses `position_x`/`position_y`
position_x          = 20                  # X offset when `center` is false
position_y          = 50                  # Y offset when `center` is false
vertical_align      = "one-third"         # "top", "center" or "one-third" when centered

[font]
fontname = "Noto Sans:size=12"            # Font to use for all text

[input]
prompt   = "> "                       # Prompt prefix on the input line
cursor   = "_"                        # Cursor character under typed text

[terminal]
program  = "kitty"                   # Terminal program for `/` commands

[border]
width    = 2                         # Border thickness in pixels (0 disables)

# ── Available themes ───────────────────────────────────────────────────────
[[themes]]
name                   = "Nord"
bgColorHex             = "#2E3440"
fgColorHex             = "#D8DEE9"
highlightBgColorHex    = "#88C0D0"
highlightFgColorHex    = "#2E3440"
borderColorHex         = "#4C566A"
matchFgColorHex        = "#FFA500"

[[themes]]
name                   = "Dracula"
bgColorHex             = "#282A36"
fgColorHex             = "#F8F8F2"
highlightBgColorHex    = "#BD93F9"
highlightFgColorHex    = "#282A36"
borderColorHex         = "#44475A"
matchFgColorHex        = "#FFA500"

# …add or remove more [[themes]] blocks as desired…

# ── Persist last theme ─────────────────────────────────────────────────────
[theme]
last_chosen = "Nord"
```

### Config option reference

| Key                               | Purpose |
|-----------------------------------|---------|
| `[window].width`                  | Width of the launcher window in pixels |
| `[window].max_visible_items`      | Maximum rows visible in the list |
| `[window].center`                 | Center the window horizontally and use `vertical_align` for vertical placement |
| `[window].position_x`             | X offset when `center` is false |
| `[window].position_y`             | Y offset when `center` is false |
| `[window].vertical_align`         | Vertical alignment when centered: `top`, `center` or `one-third` |
| `[font].fontname`                 | Xft font description |
| `[input].prompt`                  | Text prefix before the user query |
| `[input].cursor`                  | Character drawn after the query text |
| `[terminal].program`              | Terminal emulator launched for `/` commands |
| `[border].width`                  | Thickness of the outer window border (0 disables) |
| `[theme].last_chosen`             | Name of the last-selected theme |

---

## Built‑in Themes

A quick reference to the shipped themes (in the order they appear in TOML):

Nord • Dracula • Solarized Light • Solarized Dark • Gruvbox Light • Gruvbox Dark  
Catppuccin Frappe, Latte, Macchiato, Mocha • Ayu Light, Dark • Material Light, Dark  
One Light, Dark • Monokai • Monokai Pro • GitHub Light • GitHub Dark  
Cobalt • Palenight • Synthwave 84 • Tokyo Night Light • Tokyo Night • …and more

---

## Future

- **Icons & comments**: display app icons and `.comment` text alongside names.  
- **Wayland support**: investigate native layer‑shell integration (beyond X11).  
- **Plugin hooks**: let external scripts inject custom actions.  

---

## License

© 2025 DrunkenAlcoholic — MIT License  
Enjoy launching at ludicrous speed! 🚀
