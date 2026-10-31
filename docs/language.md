# The language

Everything you type into nish is Nim, more precisely NimScript, the part of Nim the compiler's VM can run. Before a line reaches the VM, nish checks whether it is a shell command. If it is, nish rewrites it into a call that runs the command, so `ls -la` becomes `run("ls -la")`.

## Commands or Nim?

A line is a command when its first word:

1. is not a Nim keyword (`for`, `let`, `proc` and so on),
2. is not a Nim name in scope (a proc, variable, type or constant, from your session or an imported module), and
3. names a program on your `PATH`, an [alias](customizing.md#aliases), or a path to an executable like `./build.sh`.

A Nim name only counts when it is written exactly as it was declared. Nim itself would accept `mkdir` for NimScript's `mkDir`, but at a shell prompt `mkdir` means the program, so that's what nish runs. Spelled `mkDir`, it's the Nim proc.

So Nim wins whenever a name means something in Nim:

| Input | Result |
| --- | --- |
| `ls -la` | runs `ls` |
| `echo "hi"` | Nim's `echo` |
| `true` | the Nim value `true`, which is an error on its own line |
| `ls = 3` | Nim (an assignment), even though `ls` is a program |
| `ls(x)`, `ls.len` | Nim, because of the `(` or `.` right after the name |

Three things override the rule:

- **Shell-only operators.** A line containing `&&`, `||`, `>>` or `>&` outside quotes is a command, whatever its first word is, because those are never Nim. `false || printf "fallback\n"` runs both programs.
- **A leading `!`.** It makes the whole line a command: `!echo x | wc -l`. Use it for lines whose first word is a Nim name, when the line only uses operators that Nim has too, like `|`, `>` and `<`.
- **Plain Nim.** `run"echo x | wc -l"` is an ordinary Nim call, so it works anywhere.

A line is split at `;` (outside quotes and brackets) first, and each part is classified on its own, since `;` separates statements in Nim too. `ls; echo "done"` runs `ls` and then Nim's `echo`.

### Commands inside Nim code

Commands work anywhere a statement does:

```nim
import std/strutils

proc backup(file: string) =
  cp @(file) @(file & ".bak")

for f in listFiles("."):
  if f.endsWith(".nim"):
    backup(f)
```

nish follows the structure of the code to stay out of the way of Nim:

- Lines inside `type`, `const`, `let` and `var` sections, inside open brackets, continuing an expression, or inside `#[ ]#` comments are never commands.
- Names declared earlier in the same input count as Nim: a proc's parameters and `result`, loop variables, and names from `let` and `var`. A parameter called `time` stays a parameter even though `time` is a program.

### When nothing matches

A line shaped like a command whose first word is neither Nim nor a program gets `nish: foo: command not found`, and `lastStatus` becomes 127. Anything else goes to the compiler, which reports errors as usual.

## Command syntax

Inside a command line, the syntax is a familiar subset of POSIX shells.

Pipes and redirects
:   `a | b`, `> file`, `>> file`, `< file`, `2> file`, `2>&1`. A digit right before `>` or `<` picks the descriptor.

Chaining
:   `a && b` runs `b` if `a` succeeded, `a || b` runs `b` if it failed, `a; b` runs both.

Background
:   `a &` starts `a` as a background [job](#jobs).

Quoting
:   `'single quotes'` are literal. `"double quotes"` expand `$VAR` and allow `\"`, `\\` and `\$`. A backslash outside quotes escapes the next character.

Expansion
:   In unquoted words: globs (`*.nim`, `file?.txt`, `[ab].txt`), `~` at the start of a word, and `$VAR` or `${VAR}`. A glob that matches nothing stays as written.

Comments
:   A `#` that starts a word begins a comment. Inside a word (`a#b`) it is an ordinary character.

There is no `$(...)` command substitution and no `if` or `while` in command syntax: Nim does those jobs. Use `sh"..."` for output and Nim's own control flow.

## Nim values in commands

`@(expr)` puts the value of a Nim expression into a command line:

```nim
let name = "notes.txt"
let flags = @["-l", "-a"]
ls @(flags) @(name)        # runs: ls -l -a notes.txt
cp @(name) "backup-@(name)"
```

- A string, number, `bool` or `char` becomes one argument, even if it contains spaces.
- A sequence or array becomes one argument per element, and an empty one becomes none.
- Inside a word or inside double quotes, the value is inserted into the text and must be a single value.
- `@(` inside single quotes, or written as `\@(`, is literal text.

## Output and status

`sh"..."` runs a command line and returns what it wrote to standard output, without trailing newlines:

```nim
let branch = sh"git branch --show-current"
let files = sh"ls src".splitLines   # needs: import std/strutils
```

`lastStatus` holds the exit status of the last command. A failed input sets it to 1, and a missing command to 127:

```nim
run("test -d build")
if lastStatus != 0:
  mkdir build
```

`run` also returns the status, so `if run("test -d build") != 0:` works too. Both `run` and `sh` take `@(...)` values as extra arguments when you call them directly: `run("ls \0", dir)`, where `\0` marks where each value goes.

## Builtins

A few commands are handled by nish itself:

`cd [dir]`
:   Changes the directory; without an argument, to your home directory. `cd "/tmp"` and `cd(dir)` are the Nim call, which also works.

`exit [status]`
:   Quits the shell, with `lastStatus` if no status is given.

`jobs`, `fg [n]`, `bg [n]`
:   Manage [jobs](#jobs). `fg %2` and `fg 2` both mean job 2.

## Jobs

Each pipeline is a job. At the prompt, the job that runs in the foreground owns the terminal:

- **Ctrl-C** stops the foreground job. The shell itself keeps running.
- **Ctrl-Z** suspends it and returns to the prompt: `[1]  Stopped   sleep 100`.
- **`cmd &`** starts a job in the background and prints its number and process ID. When it finishes, nish says so before the next prompt.
- **`jobs`** lists the background and stopped jobs, **`fg`** brings one back to the foreground, and **`bg`** lets a stopped one continue in the background.

A command captured with `sh"..."` can't be suspended, since its output could never arrive. Ctrl-C still stops it.

Scripts, `-c` and piped input have no job control, as in other shells: jobs share the shell's process group, and Ctrl-C stops the whole script.

## The NimScript API

The API that `.nims` files have is built in too: `cd`, `getEnv`, `putEnv`, `existsEnv`, `fileExists`, `dirExists`, `listFiles`, `listDirs`, `mkDir`, `rmFile`, `cpFile`, `mvFile`, `exec`, `gorgeEx` and the rest of [`system/nimscript`](https://nim-lang.org/docs/nimscript.html). nish's own additions are in the [API reference](api.md).
