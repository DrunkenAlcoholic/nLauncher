# src/themes.nim

## themes.nim — catalogue of built‑in colour schemes
## GNU GPL v3 (or later); see LICENSE.
##
## This module is data‑only: it exposes a list of `Theme` records and a tiny
## lookup helper.  No side effects.

# ── Imports ─────────────────────────────────────────────────────────────
import std/strutils           ## `toLower`

# ── Type definitions ────────────────────────────────────────────────────
type
  Theme* = object              ## One complete colour scheme.
    name*: string
    bgColorHex*: string
    fgColorHex*: string
    highlightBgColorHex*: string
    highlightFgColorHex*: string
    borderColorHex*: string

# ── Theme catalogue ─────────────────────────────────────────────────────
const themeList*: seq[Theme] =
  @[
    Theme(
      name: "Ayu Dark",
      bgColorHex: "#0F1419",
      fgColorHex: "#BFBDB6",
      highlightBgColorHex: "#59C2FF",
      highlightFgColorHex: "#0F1419",
      borderColorHex: "#1F2328",
    ),
    Theme(
      name: "Ayu Light",
      bgColorHex: "#FAFAFA",
      fgColorHex: "#5C6773",
      highlightBgColorHex: "#399EE6",
      highlightFgColorHex: "#FAFAFA",
      borderColorHex: "#F0F0F0",
    ),
    Theme(
      name: "Catppuccin Frappe",
      bgColorHex: "#303446",
      fgColorHex: "#C6D0F5",
      highlightBgColorHex: "#8CAAEE",
      highlightFgColorHex: "#303446",
      borderColorHex: "#414559",
    ),
    Theme(
      name: "Catppuccin Latte",
      bgColorHex: "#EFF1F5",
      fgColorHex: "#4C4F69",
      highlightBgColorHex: "#1E66F5",
      highlightFgColorHex: "#EFF1F5",
      borderColorHex: "#BCC0CC",
    ),
    Theme(
      name: "Catppuccin Macchiato",
      bgColorHex: "#24273A",
      fgColorHex: "#CAD3F5",
      highlightBgColorHex: "#8AADF4",
      highlightFgColorHex: "#24273A",
      borderColorHex: "#363A4F",
    ),
    Theme(
      name: "Catppuccin Mocha",
      bgColorHex: "#1E1E2E",
      fgColorHex: "#CDD6F4",
      highlightBgColorHex: "#89B4FA",
      highlightFgColorHex: "#1E1E2E",
      borderColorHex: "#313244",
    ),
    Theme(
      name: "Cobalt",
      bgColorHex: "#002240",
      fgColorHex: "#FFFFFF",
      highlightBgColorHex: "#007ACC",
      highlightFgColorHex: "#002240",
      borderColorHex: "#003366",
    ),
    Theme(
      name: "Dracula",
      bgColorHex: "#282A36",
      fgColorHex: "#F8F8F2",
      highlightBgColorHex: "#BD93F9",
      highlightFgColorHex: "#282A36",
      borderColorHex: "#44475A",
    ),
    Theme(
      name: "GitHub Dark",
      bgColorHex: "#0D1117",
      fgColorHex: "#E6EDF3",
      highlightBgColorHex: "#388BFD",
      highlightFgColorHex: "#0D1117",
      borderColorHex: "#30363D",
    ),
    Theme(
      name: "GitHub Light",
      bgColorHex: "#FFFFFF",
      fgColorHex: "#1F2328",
      highlightBgColorHex: "#0969DA",
      highlightFgColorHex: "#FFFFFF",
      borderColorHex: "#D1D9E0",
    ),
    Theme(
      name: "Gruvbox Dark",
      bgColorHex: "#282828",
      fgColorHex: "#EBDBB2",
      highlightBgColorHex: "#83A598",
      highlightFgColorHex: "#282828",
      borderColorHex: "#3C3836",
    ),
    Theme(
      name: "Gruvbox Light",
      bgColorHex: "#FBF1C7",
      fgColorHex: "#3C3836",
      highlightBgColorHex: "#83A598",
      highlightFgColorHex: "#FBF1C7",
      borderColorHex: "#EBDBB2",
    ),
    Theme(
      name: "Material Dark",
      bgColorHex: "#263238",
      fgColorHex: "#ECEFF1",
      highlightBgColorHex: "#FFAB40",
      highlightFgColorHex: "#263238",
      borderColorHex: "#37474F",
    ),
    Theme(
      name: "Material Light",
      bgColorHex: "#FAFAFA",
      fgColorHex: "#212121",
      highlightBgColorHex: "#FFAB40",
      highlightFgColorHex: "#FAFAFA",
      borderColorHex: "#BDBDBD",
    ),
    Theme(
      name: "Monokai",
      bgColorHex: "#272822",
      fgColorHex: "#F8F8F2",
      highlightBgColorHex: "#66D9EF",
      highlightFgColorHex: "#272822",
      borderColorHex: "#49483E",
    ),
    Theme(
      name: "Monokai Pro",
      bgColorHex: "#2D2A2E",
      fgColorHex: "#FCFCFA",
      highlightBgColorHex: "#78DCE8",
      highlightFgColorHex: "#2D2A2E",
      borderColorHex: "#5B595C",
    ),
    Theme(
      name: "Nord",
      bgColorHex: "#2E3440",
      fgColorHex: "#D8DEE9",
      highlightBgColorHex: "#88C0D0",
      highlightFgColorHex: "#2E3440",
      borderColorHex: "#4C566A",
    ),
    Theme(
      name: "One Dark",
      bgColorHex: "#282C34",
      fgColorHex: "#ABB2BF",
      highlightBgColorHex: "#61AFEF",
      highlightFgColorHex: "#282C34",
      borderColorHex: "#3E4451",
    ),
    Theme(
      name: "One Light",
      bgColorHex: "#FAFAFA",
      fgColorHex: "#383A42",
      highlightBgColorHex: "#4078F2",
      highlightFgColorHex: "#FAFAFA",
      borderColorHex: "#E5E5E6",
    ),
    Theme(
      name: "Palenight",
      bgColorHex: "#292D3E",
      fgColorHex: "#EEFFFF",
      highlightBgColorHex: "#82AAFF",
      highlightFgColorHex: "#292D3E",
      borderColorHex: "#444267",
    ),
    Theme(
      name: "Solarized Dark",
      bgColorHex: "#002B36",
      fgColorHex: "#839496",
      highlightBgColorHex: "#268BD2",
      highlightFgColorHex: "#002B36",
      borderColorHex: "#073642",
    ),
    Theme(
      name: "Solarized Light",
      bgColorHex: "#FDF6E3",
      fgColorHex: "#657B83",
      highlightBgColorHex: "#268BD2",
      highlightFgColorHex: "#FDF6E3",
      borderColorHex: "#EEE8D5",
    ),
    Theme(
      name: "Synthwave 84",
      bgColorHex: "#2A2139",
      fgColorHex: "#FFFFFF",
      highlightBgColorHex: "#F92AAD",
      highlightFgColorHex: "#2A2139",
      borderColorHex: "#495495",
    ),
    Theme(
      name: "Tokyo Night",
      bgColorHex: "#1A1B26",
      fgColorHex: "#A9B1D6",
      highlightBgColorHex: "#7AA2F7",
      highlightFgColorHex: "#1A1B26",
      borderColorHex: "#32344A",
    ),
    Theme(
      name: "Tokyo Night Light",
      bgColorHex: "#D5D6DB",
      fgColorHex: "#343B58",
      highlightBgColorHex: "#34548A",
      highlightFgColorHex: "#D5D6DB",
      borderColorHex: "#CBCCD1",
    ),
  ]

# ── Helpers ─────────────────────────────────────────────────────────────
proc themeByName*(name: string): Theme =
  ## Finds a theme by its name (case-insensitive).
  for th in themeList:
    if th.name.toLower == name.toLower:
      return th
  themeList[0]
