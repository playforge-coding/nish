import std/[sequtils, unittest]
import nish/[commands, input]

let r = Resolver(
  isNimSymbol: proc(name: string): bool =
    name in ["echo", "files", "true"],
  isProgram: proc(name: string): bool =
    name in ["ls", "git", "echo", "true", "rm", "./build.sh"],
)

proc texts(words: seq[Word]): seq[string] =
  words.mapIt(it.text)

suite "splitWords":
  test "quoting":
    check splitWords("""ls 'a b' "c \"d\"" e\ f""").texts ==
      @["ls", "a b", "c \"d\"", "e f"]

  test "comments only start a word":
    check splitWords("git log a#b # note").texts == @["git", "log", "a#b"]

  test "splices":
    let words = splitWords("ls @(dirs[0] & \"/x\") -l")
    check words.texts == @["ls", "dirs[0] & \"/x\"", "-l"]
    check words.mapIt(it.isNim) == @[false, true, false]

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

suite "translate":
  test "rewrites command lines and keeps indentation":
    check translate("for f in files:\n  rm -f @(f)", r) ==
      "for f in files:\n  run(@[\"rm\", \"-f\", $(f)])"

  test "leaves triple quoted strings alone":
    let code = "let s = \"\"\"\nls -la\n\"\"\"\nls"
    check translate(code, r) == "let s = \"\"\"\nls -la\n\"\"\"\nrun(@[\"ls\"])"

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
