# NimLaunch

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
| **Optional Vim navigation**          | Enable `vim_mode` for `hjkl`, `gg`, `/` search, `:q`, and a bottom command bar                                                       |
| **Live theme cycling & persistence** | Press F5 to cycle themes; saves your last choice in the TOML config                                                                  |
| **Single-instance guard**            | Second launch reuses the running session (no duplicate windows)                                                                     |
| **Theme preview mode**               | `t:` shows a lightweight preview list of available themes                                                                            |
| **Fast file search**                 | `s:` searches filesystem using `fd` (or `locate` fallback), typo-tolerant and ranked with match highlighting                         |
| **Fully themable via TOML**          | 25+ colour schemes built-in; add your own under `[[themes]]` in `nimlaunch.toml`                                                     |
| **Power actions**                    | `p:` (configurable) shows shutdown/reboot/logout entries sourced from the TOML                                                       |
| **Prefix triggers**                  | `r: …` or `!…` run shell command • `c: …` open dotfile • `t:` Theme preview • `s:` File search • custom `[[shortcuts]]` (e.g. `g:` → Google) |
| **Zero toolkit**                     | Pure Xlib + Xft + [parsetoml](https://github.com/NimParsers/parsetoml)                                                                |

---

## Building & Running

> **Skip this if you use the pre-built binary** from the [latest release](https://github.com/DrunkenAlcoholic/NimLaunch/releases) — just make sure your system has `libX11` and `libXft` installed.

### Dependencies

- **Nim**: install via the recommended [choosenim](https://nim-lang.org/install_unix.html) script:
  ```bash
  curl https://nim-lang.org/choosenim/init.sh -sSf | sh
  ```
- **X11 headers** & **Xft**:
  - Arch/Manjaro: `sudo pacman -S libx11 libxft`
  - Debian/Ubuntu: `sudo apt install libx11-dev libxft-dev`
- **Wayland note**: NimLaunch renders through XWayland, so keep the `xorg-xwayland` (or distro equivalent) package installed alongside the X11 libs above.
- **Nimble packages**:
  ```bash
  nimble install parsetoml x11
  ```

> Runtime requirement: even when using the prebuilt binary, NimLaunch needs the shared libraries from `libX11` and `libXft` available (Wayland sessions still require XWayland plus those libs).

### Build

```bash
git clone https://github.com/DrunkenAlcoholic/NimLaunch.git
cd NimLaunch
nimble release   # produces ./bin/nimlaunch
./bin/nimlaunch   # launch NimLaunch
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
| **Esc (Vim mode)**    | Insert → Normal; Normal → quit (or use `:q`)                           |
| **↑ / ↓**             | Navigate list                                                          |
| **←**                 | Backspace (alias for quick typo fix)                                   |
| **PageUp / PageDown** | Scroll list faster                                                     |
| **Home / End**        | Jump to top/bottom of list                                             |
| **F5**                | Cycle built-in themes                                                  |
| *(empty query)*       | Shows recent applications first                                        |
| *Vim mode (optional)* | `hjkl` to move, `gg`/`G`, `:q` to exit, `/` to search, `i`/`a` back to insert                              |

---

## Configuration

The first time you run `nimlaunch`, it creates:

```
~/.config/nimlaunch/nimlaunch.toml
```

Example configuration:

```toml
# nimlaunch.toml

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
vim_mode = false        # set true to enable Vim-style normal/insert modes

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

Prefixes `c:`, `p:`, `r:`/`!`, `s:`, and `t:` are built in; use other prefixes for your custom entries.

`mode = "shell"` replaces `{query}` with a shell-quoted string before running
the command. `mode = "file"` expands the path (including `~`) and opens it with
the default handler; the launcher stays open if the target is missing so you can
adjust the query.

### Run commands

Use the built-in `r:` prefix (or bare `!`) for quick shell commands. The query after
the prefix is sent to your configured terminal (falling back to `/bin/sh` when no
terminal is available).

### Power actions

Add `[[power_actions]]` entries to expose system controls (shutdown, reboot,
lock screen, etc.) behind a dedicated prefix (default `p:`). Each entry accepts:

- `label` → text displayed in the results list.
- `command` → shell command executed when selected (runs via `/bin/sh -c`).
- `mode` *(optional)* → `spawn` (default) launches in the background, `terminal`
  opens the configured terminal and runs the command there.
- `stay_open` *(optional)* → keep NimLaunch open after executing (default: close).

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
