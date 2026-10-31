# nish

A terminal shell whose language is [NimScript](https://nim-lang.org/docs/nims.html), the subset of Nim that runs in the compiler's VM. You type Nim, and lines that name a program run it, with the pipes, redirects and globs you know from other shells.

**Documentation: [playforge-coding.github.io/nish](https://playforge-coding.github.io/nish/)**

> [!WARNING]
> nish is young. It has the pieces a daily shell needs, but expect rough edges. See the [roadmap](https://playforge-coding.github.io/nish/roadmap/).

```nim
~/src> let dirs = @["src", "tests"]
~/src> for d in dirs:
  ...   ls -1 @(d)
  ...
~/src> git log --oneline | head -3 > ~/recent.txt && cat ~/recent.txt
~/src> let branch = sh"git branch --show-current"
~/src> echo "on ", branch
```

- A line is a command when its first word names a program and means nothing in Nim, so `ls -la` runs `ls` and `echo` is Nim's. Commands work inside loops and procs too.
- `@(expr)` puts a Nim value into a command, and `sh"..."` returns a command's output as a string.
- Job control, an editor with multi-line input and history search, and configuration in Nim through `~/.config/nish/init.nims`: the prompt, aliases, completion, key bindings, hooks and plugins.

## Building

nish pins Nim 2.4.0 with [mise](https://mise.jdx.dev), because it uses the compiler's internal API.

```sh
mise plugin install nim https://github.com/elijahr/vfox-nim
mise install
nimble build   # produces ./nish
nimble test
```

The binary carries the Nim standard library with it, so it runs without Nim installed. [Getting started](https://playforge-coding.github.io/nish/getting-started/) walks through a first session.

## License

[0BSD](LICENSE)
