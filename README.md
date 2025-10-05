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
| **Optional Vim navigation**          | Enable `vim_mode` for `hjkl`, `gg`, `Shift+G`, bottom command bar with `:s`/`:c`/`:t`/`:r`, `:q`, `!`                                                       |
| **Flatpak launcher support**         | Scans Flatpak export directories alongside standard `.desktop` paths                                                                |
| **Live theme cycling & persistence** | Press F5 to cycle themes; saves your last choice in the TOML config                                                                  |
| **Single-instance guard**            | Second launch reuses the running session (no duplicate windows)                                                                     |
| **Theme preview mode**               | `:t` shows a lightweight preview list of available themes                                                                            |
| **Fast file search**                 | `:s` searches filesystem using `fd` (or `locate` fallback), typo-tolerant and ranked with match highlighting                         |
| **Fully themable via TOML**          | 25+ colour schemes built-in; add your own under `[[themes]]` in `nimlaunch.toml`                                                     |
| **Power actions**                    | `:p` (configurable) shows shutdown/reboot/logout entries sourced from the TOML                                                       |
| **Prefix triggers**                  | `:r …` or `!…` run shell command • `:c …` open dotfile • `:t` theme preview • `:s …` file search • custom `[[shortcuts]]` (e.g. `:g …`) |
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

## Application discovery

NimLaunch scans `.desktop` launchers from the usual locations and caches 
the results (with modification timestamps) under `~/.cache/nimlaunch/apps.json`:

1. `~/.local/share/applications`
2. `~/.local/share/flatpak/exports/share/applications`
3. `/usr/share/applications`
4. `/var/lib/flatpak/exports/share/applications`

Launchers tagged `NoDisplay=true`, `Terminal=true`, or categorised strictly
as `Settings`/`System` are skipped so the list stays focused on launchable
applications. Everything else—including Flatpaks and custom shortcuts—appears 
exactly once in the results.

---

## Usage Cheat-sheet

| Keys / Pattern        | Action                                                                 |
| --------------------- | ---------------------------------------------------------------------- |
| *Type letters*        | Instant fuzzy filter (typo-tolerant)                                   |
| `:r …` or `!…`        | Run shell command (everything after the keyword is passed to your shell) |
| `:c …`                | Search `~/.config` for dotfiles and open in your editor                |
| `:t`                  | Preview available themes in a quick selection list                     |
| `:s …`                | Search filesystem for files and open with default application          |
| `:p …`                | Show power actions (shutdown, reboot, logout, …) configured in TOML   |
| `:g …`, `:y …`, …     | Custom shortcuts (keywords defined via `[[shortcuts]]`)               |
| **Enter**             | Launch item / run command                                              |
| **Esc**               | Quit                                                                   |
| **Esc (Vim mode)**    | Quit (or use `:q`); command bar closes with another Esc               |
| **↑ / ↓**             | Navigate list                                                          |
| **←**                 | Backspace (alias for quick typo fix)                                   |
| **PageUp / PageDown** | Scroll list faster                                                     |
| **Home / End**        | Jump to top/bottom of list                                             |
| **F5**                | Cycle built-in themes                                                  |
| *(empty query)*       | Shows recent applications first                                        |
| *Vim mode (optional)* | `hjkl` to move, `gg`/`Shift+G`, `/` opens command bar, `:s`/`:c`/`:t`/`:r`, `!`, `:q` to exit |

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
vim_mode = false        # set true to enable Vim-style command navigation (single-mode)

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

# Invoke with `:p` (or whatever prefix you choose).

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

### Vim mode quick reference

- `/` opens the bottom command bar for a fresh search (type, then press `Enter`).
- `:` opens the bar pre-filled with `:` so you can run built-ins (`:s`, `:c`, `:t`, `:r`, `:p`) or any custom prefix.
- `!` opens the bar for shell commands (mirrors the classic `!` trigger).
- `hjkl` move the selection; `gg` jumps to the top; `Shift+G` jumps to the bottom.
- `:q` exits NimLaunch; `Esc` also quits when no command is pending.
- Control shortcuts: `Ctrl+H` deletes the previous character, `Ctrl+U` clears the command line.


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
# Invoke with `:yt your terms`.

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

Reserved keywords `:c`, `:p`, `:r`/`!`, `:s`, and `:t` are built in; choose other keywords for custom entries (they still map to prefixes like `g:` internally).

`mode = "shell"` replaces `{query}` with a shell-quoted string before running
the command. `mode = "file"` expands the path (including `~`) and opens it with
the default handler; the launcher stays open if the target is missing so you can
adjust the query.

### Run commands

Use the built-in `:r` keyword (or bare `!`) for quick shell commands. The query after
the prefix is sent to your configured terminal (falling back to `/bin/sh` when no
terminal is available).

### Power actions

Add `[[power_actions]]` entries to expose system controls (shutdown, reboot,
lock screen, etc.) behind a dedicated keyword (default `:p`). Each entry accepts:

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
