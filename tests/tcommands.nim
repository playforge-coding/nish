import std/[sequtils, strutils, unittest]
import nish/[commands, input]

let r = Resolver(
  isNimSymbol: proc(name: string): bool =
    name in ["echo", "files", "true"],
  isProgram: proc(name: string): bool =
    name in ["ls", "git", "echo", "true", "rm", "./build.sh"],
)

proc text(w: Word): string =
  w.mapIt(it.text).join

proc argv(c: Command): seq[string] =
  c.words.mapIt(it.text)

suite "parseCommandLine":
  test "quoting":
    let line = parseCommandLine("""ls 'a b' "c \"d\"" e\ f""")
    check line.len == 1
    check line[0].pipeline.len == 1
    check line[0].pipeline[0].argv == @["ls", "a b", "c \"d\"", "e f"]

  test "segments keep their quote kind":
    let w = parseCommandLine("""a"b"'c'""")[0].pipeline[0].words[0]
    check w.mapIt((it.text, it.quote)) == @[
      ("a", qNone), ("b", qDouble), ("c", qSingle)
    ]
    check parseCommandLine("\"\"")[0].pipeline[0].argv == @[""]

  test "comments only start a word":
    check parseCommandLine("git log a#b # note")[0].pipeline[0].argv ==
      @["git", "log", "a#b"]

  test "pipes and chains":
    let line = parseCommandLine("a | b && c || d; e")
    check line.mapIt(it.chain) == @[chAlways, chAnd, chOr, chAlways]
    check line[0].pipeline.mapIt(it.argv) == @[@["a"], @["b"]]
    check line[3].pipeline[0].argv == @["e"]
    check parseCommandLine("a;").len == 1

  test "redirects":
    let cmd = parseCommandLine("cmd < in > out 2>> err 2>&1")[0].pipeline[0]
    check cmd.argv == @["cmd"]
    check cmd.redirects.mapIt((it.fd, it.kind, it.target.text)) ==
      @[(0, rdRead, "in"), (1, rdWrite, "out"), (2, rdAppend, "err"), (2, rdDup, "1")]

  test "a digit word with a space after it is an argument":
    let cmd = parseCommandLine("echo 2 > f")[0].pipeline[0]
    check cmd.argv == @["echo", "2"]
    check cmd.redirects[0].fd == 1

  test "syntax errors":
    for bad in ["a |", "a >", "'open", "&& a", "a &", "| a", "> f"]:
      expect ValueError:
        discard parseCommandLine(bad)

  test "countSplices":
    check countSplices(parseCommandLine("a \0 b\0c > \0")[0].pipeline) == 3

suite "isCommandLine":
  test "programs that are not Nim symbols":
    check isCommandLine("ls -la", r)
    check isCommandLine("  git status", r)
    check isCommandLine("./build.sh --fast", r)

  test "Nim wins":
    check not isCommandLine("echo files", r) # a Nim symbol and a program
    check not isCommandLine("true", r)
    check not isCommandLine("for f in files:", r) # keyword
    check not isCommandLine("ls(x)", r)
    check not isCommandLine("ls.len", r)
    check not isCommandLine("ls = 3", r)
    check not isCommandLine("nosuchprogram x", r)
    check not isCommandLine("# ls", r)

  test "shell-only operators make a command of any line":
    check isCommandLine("true && ls", r)
    check isCommandLine("echo a || echo b", r)
    check isCommandLine("echo x >> f", r)
    check isCommandLine("echo x 2>&1", r)
    check isCommandLine("echo x 2> f", r)
    check not isCommandLine("echo \"a && b\"", r)
    check not isCommandLine("echo x > f", r) # `>` is Nim too
    check not isCommandLine("echo 2 > 1", r)

  test "a leading ! makes the whole line a command":
    check isCommandLine("!echo x | wc -l", r)
    check isCommandLine("  !true", r)

  test "the part before the first ; decides":
    check isCommandLine("ls; echo x", r)
    check not isCommandLine("echo x; ls", r)

  test "builtins":
    check isCommandLine("cd", r)
    check isCommandLine("cd /tmp", r)
    check isCommandLine("cd ..", r)
    check isCommandLine("cd @(d)/x", r)
    check not isCommandLine("cd \"/tmp\"", r)
    check not isCommandLine("cd(x)", r)
    check not isCommandLine("cd files", r) # a Nim symbol
    check isCommandLine("exit", r)
    check isCommandLine("exit 3", r)
    check not isCommandLine("exit x", r)

suite "translate":
  test "extractSplices":
    check extractSplices("""printf "@(a)" '@(b)' @(f(1, ")"))""") ==
      (line: "printf \"\0\" '@(b)' \0", exprs: @["a", "f(1, \")\")"])
    expect ValueError:
      discard extractSplices("ls @(open")

  test "rewrites command lines and keeps indentation":
    check translate("for f in files:\n  rm -f @(f)", r) ==
      "for f in files:\n  run(\"rm -f \\x00\", f)"

  test "builtins":
    check translate("cd", r) == "cd(getEnv(\"HOME\"))"
    check translate("cd ~/x @(d)", r) == "cd(word(\"~/x \\x00\", d))"
    check translate("exit", r) == "quit(lastStatus)"
    check translate("exit 3", r) == "quit(3)"

  test "each part between semicolons is classified on its own":
    check translate("ls; echo x", r) == "run(\"ls\"); echo x"
    check translate("  ls -a; ls", r) == "  run(\"ls -a\"); run(\"ls\")"
    check translate("echo \"a; b\"; ls", r) == "echo \"a; b\"; run(\"ls\")"
    check translate("proc f(a: int; b: int) = ls", r) == "proc f(a: int; b: int) = ls"
    check translate("true && ls; echo x", r) == "run(\"true && ls\"); echo x"

  test "a leading ! keeps the whole line":
    check translate("!echo x | wc -l; echo y", r) == "run(\"echo x | wc -l; echo y\")"
    check translate("  ! ls @(d)", r) == "  run(\"ls \\x00\", d)"

  test "leaves triple quoted strings alone":
    let code = "let s = \"\"\"\nls -la\n\"\"\"\nls"
    check translate(code, r) == "let s = \"\"\"\nls -la\n\"\"\"\nrun(\"ls\")"

suite "chunks":
  let isCommand = proc(line: string): bool =
    isCommandLine(line, r)

  test "scripts split at top-level statements":
    let lines = @[
      "let x = 1", "if x == 1:", "  echo x", "", "  echo 2", "else:", "  echo 3",
      "rm *", "echo x",
    ]
    check splitChunks(lines, isCommand).mapIt(it.line) == @[1, 2, 8, 9]

  test "the prompt reads until a blank line ends a block":
    var input = @["for i in 0..2:", "  echo i", "", "ls *"]
    let read: LineReader = proc(continuation: bool, line: var string): bool =
      if input.len == 0:
        return false
      line = input[0]
      input.delete(0)
      true
    var chunk = ""
    check readChunk(read, isCommand, chunk)
    check chunk == "for i in 0..2:\n  echo i\n"
    check readChunk(read, isCommand, chunk)
    check chunk == "ls *"
    check not readChunk(read, isCommand, chunk)
