# Customizing

nish is configured in Nim. When an interactive session starts, nish runs `~/.config/nish/init.nims` (or `$XDG_CONFIG_HOME/nish/init.nims`), and everything in it works the same as typing it at the prompt. Errors in it are reported with its file name and line, and the shell starts anyway.

```nim
import std/strutils

alias "ll", "ls -la"
alias "gs", "git status"

prompt = proc(): string =
  let branch = sh"git branch --show-current 2> /dev/null"
  "\e[1;34m" & tildePath(getCurrentDir()) & "\e[0m" &
    (if branch.len > 0: " (" & branch & ")" else: "") & "> "

onDirChange.add proc(dir: string) =
  ls

completers.add proc(line, word: string): seq[string] =
  if line.startsWith("git ") and line.count(' ') == 1:
    for sub in ["status", "commit", "push", "pull", "log"]:
      if sub.startsWith(word):
        result.add sub
```

Start nish with `--no-init` to skip the file.

## Aliases

`alias name, line` makes `name` stand for the start of a command line:

```nim
alias "ll", "ls -la"
ll src           # runs: ls -la src
alias "ls", "ls -G"
```

An alias can refer to itself, as `ls` does here, and to other aliases. Its name counts as a command, so `ll` works even though there is no `ll` program.

## The prompt

`prompt` is a proc that returns the prompt string, called before every input. `continuationPrompt` is the one shown on the following lines of a multi-line input. Both may use color codes: the editor leaves them out when it measures the line.

`tildePath(path)` writes your home directory as `~`, which is handy for prompts.

## Hooks

Hooks are procs that nish calls at certain moments. They run for input typed at the prompt, not for scripts.

`onPreCommand: seq[proc(line: string)]`
:   Before each input is evaluated, with the input.

`onCommandDone: seq[proc(line: string, status: int)]`
:   After each input, with its [`lastStatus`](language.md#output-and-status).

`onDirChange: seq[proc(dir: string)]`
:   Before a prompt, when the current directory has changed.

`completers: seq[Completer]`
:   Asked when you press Tab, see [Completion](#completion).

Add to them with `.add`. A hook that raises an error doesn't take the shell down: nish reports the error and carries on with a fallback, such as a plain `nish> ` prompt.

## Completion

Tab completes the word before the cursor. The default completer offers programs, Nim names in scope and builtins for the first word of a line, and file names after it (`~/` included). If there are several candidates, Tab completes their common start and then lists them.

A completer is a `proc(line, word: string): seq[string]`: it gets the whole line up to the cursor and the word being completed, and returns replacements for that word. Every completer in `completers` is asked, and their answers are combined.

## Key bindings

`bindKey` binds a key to a Nim proc that runs instead of the editor's own action:

```nim
bindKey "ctrl-t", proc() =
  editorSetText("time " & editorText(), editorCursor() + 5)

bindKey "alt-g", proc() =
  editorInsert(sh"git branch --show-current")
```

Inside the proc, `editorText()` and `editorCursor()` read the input being edited, and `editorSetText` and `editorInsert` change it. Key names look like `ctrl-t`, `alt-x`, `up`, `ctrl-right`, `pageup` and `delete`. Printable characters can't be bound.

## The line editor

| Keys | Action |
| --- | --- |
| Enter | Accept the input, or add a line if a block is still open |
| Ctrl-J, Alt-Enter | Add a line |
| Tab | Complete |
| Up, Down | Move between lines of the input, then through the history |
| Ctrl-P, Ctrl-N | Previous and next history entry |
| Ctrl-R | Search the history; Ctrl-R again for older matches, Enter to take one, Ctrl-G to cancel |
| Left, Right, Ctrl-B, Ctrl-F | Move by character |
| Alt-B, Alt-F, Ctrl-Left, Ctrl-Right | Move by word |
| Home, End, Ctrl-A, Ctrl-E | Start and end of the line |
| Backspace, Delete, Ctrl-D | Delete a character; Ctrl-D on an empty input quits |
| Ctrl-W, Alt-Backspace | Delete the word before the cursor |
| Alt-D | Delete the word after the cursor |
| Ctrl-K, Ctrl-U | Delete to the end or the start of the line |
| Ctrl-Y | Insert the text deleted last |
| Ctrl-L | Clear the screen |
| Ctrl-C | Discard the input |

A pasted block is inserted as a whole and runs only when you press Enter.

!!! tip "Alt on macOS"
    macOS terminals type special characters with Option by default, so the Alt keys don't reach nish. In Terminal, turn on "Use Option as Meta key" in the profile's keyboard settings; in iTerm2, set the Option key to "Esc+".

History is saved after every input, in `history` in nish's data directory, and the last 10,000 entries are kept. The data directory is `~/.local/share/nish` on Linux and `~/Library/Application Support/nish` on macOS, or `$XDG_DATA_HOME/nish` when that is set.

## Plugins

A plugin is a Nim module. nish looks for modules in `plugins/` under `~/.config/nish` and under its data directory (see [above](#the-line-editor)), directly or one directory down, so a cloned repository works as it is. Import a plugin from `init.nims`:

```nim
import gitprompt
```

A plugin uses the same API as `init.nims`. It imports `nishapi` to reach it:

```nim
# ~/.config/nish/plugins/gitprompt/gitprompt.nim
import nishapi

proc branch(): string =
  sh"git branch --show-current 2> /dev/null"

prompt = proc(): string =
  let b = branch()
  tildePath(getCurrentDir()) & (if b.len > 0: " [" & b & "]" else: "") & "> "
```

Plugins run in the VM like everything else, so they can't call C libraries. Anything beyond NimScript has to come from nish's [API](api.md).
