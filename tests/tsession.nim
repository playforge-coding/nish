import std/unittest
import nish/session

let s = newSession()

test "state carries across inputs":
  check s.eval("var answer = 6 * 7")
  check s.eval("doAssert answer == 42")

test "an error is reported and the session goes on":
  check not s.eval("undefinedThing")
  check not s.eval("doAssert answer == 41")
  check s.eval("answer += 1\ndoAssert answer == 43")

test "commands run through the host":
  check s.eval("doAssert run(@[\"true\"]) == 0")
  check s.eval("doAssert run(@[\"false\"]) == 1")
  check s.eval("let code = run(@[\"nish-no-such-program\"])")
  check s.eval("doAssert code == 127")

test "command lines see Nim symbols":
  check s.isNimSymbol("answer")
  check s.isNimSymbol("echo")
  check not s.isNimSymbol("ls")
  check s.eval("var dir = \"/\"\nls @(dir)")

test "the NimScript API is there":
  check s.eval("doAssert getEnv(\"HOME\").len > 0")
