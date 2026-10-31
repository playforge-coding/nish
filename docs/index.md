# nish

nish is a terminal shell whose language is [NimScript](https://nim-lang.org/docs/nims.html), the subset of Nim that runs in the Nim compiler's VM. You type Nim, and lines that name a program run it, with the pipes, redirects and globs you know from other shells.

```nim
~/src> let dirs = @["src", "tests"]
~/src> for d in dirs:
  ...   ls -1 @(d) | head -3
  ...
~/src> git log --oneline | head -3 > ~/recent.txt && cat ~/recent.txt
~/src> let branch = sh"git branch --show-current"
~/src> echo "on ", branch
```

## What you get

- **A real language.** Variables, procs, loops, types and the Nim standard library, with everything you define staying in scope for the rest of the session.
- **Commands where you expect them.** A line is a command when its first word names a program and means nothing in Nim. Command lines work anywhere a statement does, inside loops and procs too.
- **Nim values in commands.** `@(expr)` puts a value into a command line, and a sequence becomes one argument per element.
- **Output as values.** `sh"..."` runs a command line and returns what it printed, so shell output flows straight into Nim code.
- **Job control.** Pipelines run as jobs: Ctrl-Z stops one, `&` runs one in the background, and `jobs`, `fg` and `bg` manage them.
- **Configured in Nim.** `~/.config/nish/init.nims` sets the prompt, aliases, completions, key bindings and hooks, and plugins are Nim modules you import.
- **Its own line editor.** Multi-line input, bracketed paste, history search, Tab completion and colored prompts.
- **One binary.** nish carries the parts of the Nim standard library the VM needs, so it runs without Nim installed.

!!! warning "Early days"
    nish is young. It has the pieces a daily shell needs, but expect rough edges. The [roadmap](roadmap.md) lists what comes next.

## Where to go next

- [Getting started](getting-started.md) builds nish and walks through a first session.
- [The language](language.md) explains how nish tells commands from Nim, and the command syntax.
- [Customizing](customizing.md) covers `init.nims`, hooks, aliases, key bindings and plugins.
- [API reference](api.md) lists everything nish adds to NimScript.
- [Architecture](architecture.md) and [Development](development.md) are for working on nish itself.
