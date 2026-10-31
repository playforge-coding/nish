import std/[os, strutils, unittest]
import nish/session

let s = newSession()
removeDir(getTempDir() / "nish-tsession")
createDir(getTempDir() / "nish-tsession")
# Resolved, because `cd` tests compare it with `getCurrentDir()`.
let tmp = expandFilename(getTempDir() / "nish-tsession")
writeFile(tmp / "a.txt", "")
writeFile(tmp / "b.txt", "")
putEnv("NISH_TEST_VAR", "v")
check s.eval("let tmp = \"" & tmp & "\"")

test "state carries across inputs":
  check s.eval("var answer = 6 * 7")
  check s.eval("doAssert answer == 42")

var messages: seq[string] = @[]
s.onMessage = proc(line: string) =
  messages.add line

test "an error is reported and the session goes on":
  check not s.eval("undefinedThing()")
  check messages == @["Error: undeclared identifier: 'undefinedThing'"]
  messages = @[]
  check not s.eval("doAssert answer == 41")
  check messages[^1].endsWith("[AssertionDefect]")
  check s.eval("answer += 1\ndoAssert answer == 43")

test "message positions":
  # A fresh name each time: the compiler remembers a failed one as declared.
  messages = @[]
  check not s.eval("let ok = 1\nnope1(ok)")
  check messages == @["line 2: Error: undeclared identifier: 'nope1'"]
  s.sourceName = "demo.nims"
  messages = @[]
  check not s.eval("nope2(1)", line = 7)
  check messages == @["demo.nims(7, 1) Error: undeclared identifier: 'nope2'"]
  s.sourceName = ""

test "detail lines of the first error are kept":
  messages = @[]
  check not s.eval("let n: int = \"text\"")
  check messages[0] ==
    "Error: type mismatch: got 'string' for '\"text\"' but expected 'int'"
  check messages.len == 1

test "lastStatus after a failed input":
  check s.eval("run(\"true\")")
  check not s.eval("nope3()")
  check s.lastStatus == 1
  check not s.eval("nosuchprogram")
  check s.lastStatus == 127
  check s.eval("run(\"test 1 = 2\")")
  check s.lastStatus == 1

test "echo is not an error message":
  messages = @[]
  check s.eval("echo \"to stdout\"")
  check messages.len == 0

test "command not found":
  messages = @[]
  check not s.eval("nosuchprogram -v")
  check not s.eval("no-such-program")
  check messages.len == 0 # nish reports it itself, on stderr
  check s.eval("doAssert lastStatus == 127")

test "commands run through the host":
  check s.eval("doAssert run(\"true\") == 0")
  check s.eval("doAssert run(\"test 1 = 2\") == 1 and lastStatus == 1")
  check s.eval("doAssert run(\"nishnosuchprogram\") == 127 and lastStatus == 127")
  check s.eval("doAssert run(\"printf >\") == 2") # a syntax error

test "pipes, capture and chaining":
  check s.eval("doAssert sh\"printf 'b\\na\\n' | sort\" == \"a\\nb\"")
  check s.eval("doAssert sh\"test 1 = 2 && printf yes || printf no\" == \"no\"")
  check s.eval("doAssert sh\"printf a; printf b\" == \"ab\"")
  check s.eval("doAssert sh\"printf a; test 1 = 2\" == \"a\" and lastStatus == 1")

test "redirects":
  check s.eval("printf one > @(tmp)/out.txt\nprintf two >> @(tmp)/out.txt")
  check s.eval("doAssert sh(\"cat < \" & tmp & \"/out.txt\") == \"onetwo\"")
  check s.eval("doAssert sh(\"ls \" & tmp & \"/missing 2>&1\").len > 0")
  check s.eval("doAssert sh(\"ls \" & tmp & \"/missing 2> /dev/null\") == \"\"")

test "expansion":
  check s.eval("doAssert words(\"\\0/[ab].txt\", tmp).len == 2")
  check s.eval("doAssert words(\"'*.txt'\") == @[\"*.txt\"]")
  check s.eval("doAssert words(\"nomatch*.txt\") == @[\"nomatch*.txt\"]")
  check s.eval("doAssert word(\"~\") == getEnv(\"HOME\")")
  check s.eval("doAssert word(\"$NISH_TEST_VAR\") == \"v\"")
  check s.eval("doAssert word(\"\\\"${NISH_TEST_VAR}x\\\"\") == \"vx\"")
  check s.eval("doAssert word(\"'$NISH_TEST_VAR'\") == \"$NISH_TEST_VAR\"")

test "splices":
  check s.eval("let xs = @[\"a\", \"b\"]")
  check s.eval(
    "doAssert words(\"x \\0 \\0 p\\0q\", xs, 3, xs[0]) == @[\"x\", \"a\", \"b\", \"3\", \"paq\"]"
  )
  check s.eval("doAssert words(\"\\0\", newSeq[string]()).len == 0")
  check s.eval("doAssert sh(\"printf %s \\0\") == \"\" and lastStatus == 2")
    # too few values

test "lines that are commands despite their first word":
  check s.eval("true && printf and > @(tmp)/and.txt")
  check s.eval("doAssert sh(\"cat \" & tmp & \"/and.txt\") == \"and\"")
  check s.eval("!echo hi | tr h j > @(tmp)/bang.txt")
  check s.eval("doAssert sh(\"cat \" & tmp & \"/bang.txt\") == \"ji\"")
  check s.eval("var seen = 0")
  check s.eval("ls @(tmp) > /dev/null; seen += 1; ls @(tmp) > /dev/null")
  check s.eval("doAssert seen == 1 and lastStatus == 0")

test "background jobs":
  check s.eval("doAssert run(\"sleep 0.2 &\") == 0")
  check s.eval("doAssert fg() == 0 and lastStatus == 0")
  check s.eval("sleep 0.1 & test 1 = 2 &")
  check s.eval("doAssert fg(2) == 1")
  check s.eval("doAssert fg(1) == 0")
  check s.eval("doAssert fg() == 1") # no job left

test "aliases":
  check s.eval("alias \"hello\", \"printf hi\"")
  check s.eval("doAssert sh\"hello\" == \"hi\"")
  check s.eval("hello > @(tmp)/alias.txt") # an alias name is a command
  check s.eval("doAssert sh(\"cat \" & tmp & \"/alias.txt\") == \"hi\"")
  check s.eval("alias \"ls\", \"ls -d\"") # refers to itself
  check s.eval("doAssert sh(\"ls \" & tmp) == tmp")
  check s.eval("doAssert words(\"hello there\") == @[\"printf\", \"hi\", \"there\"]")

test "hooks":
  check s.hookString("nishPrompt", "").endsWith("> ")
  check s.eval("prompt = proc(): string = \"custom> \"")
  check s.hookString("nishPrompt", "") == "custom> "
  check s.eval("var statuses: seq[int] = @[]")
  check s.eval(
    "onCommandDone.add proc(line: string, status: int) = statuses.add status"
  )
  s.runHook("nishCommandDone", strNode("x"), intNode(7))
  check s.eval("doAssert statuses == @[7]")
  # A failing hook falls back and doesn't take the session down.
  check s.eval("prompt = proc(): string = raise newException(ValueError, \"boom\")")
  check s.hookString("nishPrompt", "fallback> ") == "fallback> "
  check s.eval("prompt = proc(): string = \"ok> \"")
  check s.hookString("nishPrompt", "") == "ok> "

test "key bindings":
  check s.eval("var pressed: seq[string] = @[]")
  check s.eval("bindKey \"ctrl-t\", proc() = pressed.add \"t\"")
  check s.eval("bindKey \"ctrl-t\", proc() = pressed.add \"t2\"") # replaces
  check s.eval("doAssert nishKeyPressed(\"ctrl-t\") and not nishKeyPressed(\"ctrl-q\")")
  check s.eval("doAssert pressed == @[\"t2\"]")
  check s.eval("doAssert editorText() == \"\" and editorCursor() == 0")
    # no editor active

test "completion":
  check "echo" in s.complete("ec")
  check "ls" in s.complete("l")
  check "cd" in s.complete("c")
  check ("cat " & tmp & "/a.txt") in s.complete("cat " & tmp & "/a")
  check s.eval(
    "completers.add proc(line, word: string): seq[string] = @[\"zzz\" & word]"
  )
  check "zzzq" in s.complete("q")
  check ("x zzzq") in s.complete("x q")

test "command lines see Nim symbols":
  check s.isNimSymbol("answer")
  check s.isNimSymbol("echo")
  check not s.isNimSymbol("ls")
  # Nim matches names style insensitively, and so does `isNimSymbol`; only
  # deciding a name that is also a program asks for the exact spelling, so
  # `mkdir` is the program and `mkDir` the NimScript proc.
  check s.isNimSymbol("mkDir", exact = true)
  check s.isNimSymbol("mkdir")
  check not s.isNimSymbol("mkdir", exact = true)
  check s.eval("mkdir -p @(tmp)/made/here\ndoAssert dirExists(tmp & \"/made/here\")")
  # Other spellings of a Nim name are still Nim, not "command not found".
  check s.eval(
    "var greeted = \"\"\nproc say_hi(name: string) = greeted = name\nsayHi \"bob\""
  )
  check s.eval("doAssert greeted == \"bob\"")
  check s.eval("let myDir = \"" & tmp & "\"")
  let here = getCurrentDir()
  check s.eval("cd mydir\ndoAssert getCurrentDir() == myDir") # the variable
  setCurrentDir(here)
  # An overload spelled like the program is found among the candidates.
  check s.eval("proc mkdir(x: int): int = x")
  check s.isNimSymbol("mkdir", exact = true)
  check s.eval(
    "doAssert sh(\"ls \" & tmp & \"/[ab].txt | wc -l | tr -d ' '\") == \"2\""
  )

test "the cd builtin":
  let here = getCurrentDir()
  check s.eval("cd @(tmp)\ndoAssert getCurrentDir() == tmp")
  check s.eval("cd ..\ndoAssert getCurrentDir() == \"" & tmp.parentDir & "\"")
  check s.eval("cd\ndoAssert getCurrentDir() == getEnv(\"HOME\")")
  check s.eval("cd \"" & here & "\"")
  check getCurrentDir() == here

test "the NimScript API is there":
  check s.eval("doAssert getEnv(\"HOME\").len > 0")

removeDir(tmp)
