# nLauncher

> A lightning-fast, X11-native application and command launcher written in Nim.\
> Minimal dependencies, zero toolkit bloat, instant fuzzy search, and rich theming.



---

## Highlights

| Feature | Notes |
| ------- | ----- |
| **Scored fuzzy search**              | Better ranking on prefixes, word starts, and tight matches                                                                           |
| **Per-character match highlighting** | Matching letters are bold & colored (theme-configurable)                                                                             |
| **Live clock**                       | Small HH\:mm clock in the bottom-right                                                                                               |
| **Sub-1 ms startup (bench mode)**    | `--bench` flag for raw launch timing                                                                                                 |
| **Recent-apps history**              | Empty query shows your last launches first                                                                                           |
| **100% keyboard-driven**             | Arrow keys / PageUp / PageDown / Home / End / Left / Right / Enter / Esc                                                             |
| **Live theme cycling & persistence** | Press F5 to cycle themes; saves your last choice in the TOML config                                                                  |
| **Theme preview mode**               | `t:` shows a lightweight preview list of available themes                                                                            |
| **Fast file search**                 | `s:` searches filesystem using `fd` (or `locate` fallback), typo-tolerant and ranked with match highlighting                         |
| **Fully themable via TOML**          | 25+ colour schemes built-in; add your own under `[[themes]]` in `nlauncher.toml`                                                     |
| **Power actions**                    | `p:` (configurable) shows shutdown/reboot/logout entries sourced from the TOML                                                       |
| **Prefix triggers**                  | `r: …` run shell command • `c: …` open dotfile • `t:` Theme preview • `s:` File search • custom `[[shortcuts]]` (e.g. `g:` → Google) |
| **Zero toolkit**                     | Pure Xlib + Xft + [parsetoml](https://github.com/NimParsers/parsetoml)                                                                |

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
| `r: …` or `!…`        | Run shell command (everything after the prefix is passed to your shell) |
| `c: …`                | Search `~/.config` for dotfiles and open in your editor                |
| `t:`                  | Preview available themes in a quick selection list                     |
| `s:`                  | Search filesystem for files and open with default application          |
| `p:`                  | Show power actions (shutdown, reboot, logout, …) configured in TOML   |
| `g:, y:, w:, …`       | Example custom shortcuts (configure via `[[shortcuts]]`)               |
| **Enter**             | Launch item / run command                                              |
| **Esc**               | Quit                                                                   |
| **↑ / ↓**             | Navigate list                                                          |
| **←**                 | Backspace (alias for quick typo fix)                                   |
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

[power]
prefix = "p:"

[[power_actions]]
label   = "Shutdown"
command = "systemctl poweroff"

[[power_actions]]
label   = "Reboot"
command = "systemctl reboot"

[[power_actions]]
label   = "Logout"
command = "loginctl terminate-user $USER"

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

### Custom shortcuts

Define additional prefix triggers by adding `[[shortcuts]]` blocks to the
config. Each entry accepts a `prefix` (for example `g:`), a `label` displayed
before the query, a `base` template that can reference `{query}`, and an
optional `mode`:

```toml
[[shortcuts]]
prefix = "yt:"
label  = "Search YouTube: "
base   = "https://www.youtube.com/results?search_query={query}"
mode   = "url"    # default; other values: "shell", "file"

[[shortcuts]]
prefix = "rg:"
label  = "ripgrep in repo: "
base   = "cd ~/code && rg {query}"
mode   = "shell"

[[shortcuts]]
prefix = "md:"
label  = "Open note: "
base   = "~/notes/{query}.md"
mode   = "file"
```

`mode = "shell"` replaces `{query}` with a shell-quoted string before running
the command. `mode = "file"` expands the path (including `~`) and opens it with
the default handler; the launcher stays open if the target is missing so you can
adjust the query.

### Power actions

Add `[[power_actions]]` entries to expose system controls (shutdown, reboot,
lock screen, etc.) behind a dedicated prefix (default `p:`). Each entry accepts:

- `label` → text displayed in the results list.
- `command` → shell command executed when selected (runs via `/bin/sh -c`).
- `mode` *(optional)* → `spawn` (default) launches in the background, `terminal`
  opens the configured terminal and runs the command there.
- `stay_open` *(optional)* → keep nLauncher open after executing (default: close).

Override the prefix by setting `[power].prefix = "x:"` (or leave empty to
disable the trigger entirely).

---

## Built-in Themes

Nord • Dracula • Solarized Light • Solarized Dark • Gruvbox Light • Gruvbox Dark\
Catppuccin Frappe, Latte, Macchiato, Mocha • Ayu Light, Dark • Material Light, Dark\
One Light, Dark • Monokai • Monokai Pro • GitHub Light • GitHub Dark\
Cobalt • Palenight • Synthwave 84 • Tokyo Night Light • Tokyo Night • …and more

---

## Future

- **Icons & comments**: display app icons and `.comment` text alongside names.
- **Wayland support**: investigate native layer-shell integration (beyond X11).

---

## License

© 2025 DrunkenAlcoholic — MIT License\
Enjoy launching at ludicrous speed! 🚀
