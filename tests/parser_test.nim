# tests/parser_test.nim
## parser_test.nim — unit tests for parser utilities
## MIT; see LICENSE for details.

import unittest
import ../src/parser

suite "getBaseExec":
  test "extract kitty binary":
    check getBaseExec("/usr/bin/kitty --single-instance") == "kitty"

  test "extract code binary":
    check getBaseExec("code %F") == "code"

