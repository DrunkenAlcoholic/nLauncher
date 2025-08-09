# nLauncher

> A lightning-fast, X11-native application and command launcher written in Nim.\
> Minimal dependencies, zero toolkit bloat, instant fuzzy search, and rich theming.

![nLauncher screenshot](Screenshot.gif)

---

## Highlights

| Feature | Notes |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------- |
| **Scored fuzzy search**              | Better ranking on prefixes, word starts, and tight matches                                                        |
| **Per-character match highlighting** | Matching letters are bold & colored (theme-configurable)                                                          |
| **Live clock**                       | Small HH\:mm clock in the bottom-right                                                                            |
| **Sub-1 ms startup (bench mode)**    | `--bench` flag for raw launch timing                                                                              |
| **Recent-apps history**              | Empty query shows your last launches first                                                                        |
| **100% keyboard-driven**             | Arrow keys / PageUp / PageDown / Home / End / Left / Right / Enter / Esc                                          |
| **Live theme cycling & persistence** | Press F5 to cycle themes; saves your last choice in the TOML config                                               |
| **Theme preview mode**               | `t:` shows a lightweight preview list of available themes                                                         |
| **Fully themable via TOML**          | 25+ colour schemes built-in; add your own under `[[themes]]` in `nlauncher.toml`                                  |
| **Slash triggers**                   | `/ …` run shell command • `/c …` open dotfile • `/y …` YouTube • `/g …` Google • `/w …` Wiki • `t:` Theme preview |
| **Zero toolkit**                     | Pure Xlib + Xft + [parsetoml](https://github.com/pragmagic/parsetoml)                                             |

---

## Building & Running

> **Skip this if you use the pre-built binary** from the latest release.

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

### Command-line flags

- `--bench` → prints millisecond-precision startup timings and exits

---

## Usage Cheat-sheet

| Keys / Pattern        | Action                                                                 |
| --------------------- | ---------------------------------------------------------------------- |
| *Type letters*        | Instant fuzzy filter (typo-tolerant)                                   |
| `/ …`                 | Run shell command (everything after the slash is passed to your shell) |
| `/c …`                | Search `~/.config` for dotfiles and open in your editor                |
| `/y …`                | Search YouTube in browser                                              |
| `/g …`                | Google search in browser                                               |
| `/w …`                | Wikipedia search in browser                                            |
| `t:`                  | Preview available themes in a quick selection list                     |
| **Enter**             | Launch item / run command                                              |
| **Esc**               | Quit                                                                   |
| **↑ / ↓**             | Navigate list                                                          |
| **← / →**             | Move cursor in query text                                              |
| **PageUp / PageDown** | Scroll list faster                                                     |
| **Home / End**        | Jump to top/bottom of list                                             |
| **F5**                | Cycle built-in themes                                                  |
| *(empty query)*       | Shows recent applications first                                        |

---

## Configuration

The first time you run `nlauncher`, it creates:

```
~/.config/nlauncher/nlauncher.toml
```

Example configuration:

```toml
# nlauncher.toml

[window]
width               = 500
max_visible_items   = 10
center              = true
position_x          = 20
position_y          = 50
vertical_align      = "one-third"

[font]
fontname = "Noto Sans:size=12"

[input]
prompt   = "> "
cursor   = "_"

[terminal]
program  = "kitty"

[border]
width    = 2

[[themes]]
name                   = "Nord"
bgColorHex             = "#2E3440"
fgColorHex             = "#D8DEE9"
highlightBgColorHex    = "#88C0D0"
highlightFgColorHex    = "#2E3440"
borderColorHex         = "#4C566A"
matchFgColorHex        = "#f8c291"

[theme]
last_chosen = "Nord"
```

---

## Built-in Themes

Nord • Dracula • Solarized Light • Solarized Dark • Gruvbox Light • Gruvbox Dark\
Catppuccin Frappe, Latte, Macchiato, Mocha • Ayu Light, Dark • Material Light, Dark\
One Light, Dark • Monokai • Monokai Pro • GitHub Light • GitHub Dark\
Cobalt • Palenight • Synthwave 84 • Tokyo Night Light • Tokyo Night • …and more


## Future

- **Icons & comments**: display app icons and `.comment` text alongside names.
- **Wayland support**: investigate native layer-shell integration (beyond X11).
- **Plugin hooks**: let external scripts inject custom actions.


## License

© 2025 DrunkenAlcoholic — MIT License\
Enjoy launching at ludicrous speed! 🚀

