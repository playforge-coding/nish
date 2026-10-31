# Roadmap

This page lists what is planned for nish, roughly in the order it will happen. It is a plan, not a promise: priorities move as daily use turns up problems. Finished items stay checked off in their section, so each section shows how its goal is coming along.

## Done: the MVP

The goal was a shell good enough for daily interactive use and small scripts.

- [x] **The embedded VM.** One long-lived NimScript session whose definitions carry over between inputs, with errors reported without losing the session's scope.
- [x] **Nim-first command lines.** Lines that name a program run it, everything else is Nim, and commands work inside Nim blocks.
- [x] **A portable binary.** The standard library is built in and unpacked on first run, so nish runs without Nim installed.
- [x] **Shell syntax.** Pipes, redirects, `&&`, `||`, `;`, globs, `~`, `$VAR` and quoting, with `@(expr)` for Nim values and `sh"..."` for output.
- [x] **Overrides for "Nim wins".** Shell-only operators, a leading `!` and `;` splitting, for lines whose first word is a Nim name.
- [x] **Job control.** Process groups, Ctrl-Z, `&`, `jobs`, `fg` and `bg`.
- [x] **Customizing.** `init.nims`, hooks, aliases, Tab completion, saved history and plugins.
- [x] **A line editor of its own.** Multi-line input, bracketed paste, colored prompts, history search and key bindings written in Nim.
- [x] **Readable errors.** One error per input, positions that make sense at the prompt and in scripts, and "command not found".
- [x] **This documentation.**

## Next: everyday polish

These are the rough edges most likely to bother someone using nish every day.

- [ ] **Environment for one command.** `FOO=1 make` should set `FOO` for `make` only. Today the line is read as a Nim assignment.
- [ ] **Interrupting Nim code.** Ctrl-C stops programs, but not a Nim loop that runs too long, because the VM has no way to be interrupted from outside. This likely needs a small patch to the compiler's VM, checking a flag on backward jumps.
- [ ] **Stopped jobs on exit.** Warn when quitting with stopped jobs, the way other shells do, and quit for real on the second try.
- [ ] **Editor: resizing and wide characters.** Redraw correctly when the terminal is resized during an input, and count double-width characters (CJK, many emoji) as two columns.
- [ ] **Faster completion.** Programs on `PATH` are listed again on every Tab. Cache the list and refresh it when `PATH` or a directory on it changes.
- [ ] **CI on macOS and Linux.** Build and run the tests on both on every pull request. nish is developed on macOS, and Linux has had little testing so far.

## Plugins and customization

The goal is for nish to be as customizable as zsh, with Nim as the language for all of it.

- [ ] **Plugin manager.** `use "github.com/user/nish-plugin"` in `init.nims` clones a plugin into the plugin directory on first use and imports it. Written in NimScript, as a plugin itself.
- [ ] **A versioned plugin API.** A `nishApiVersion` constant, and a promise about what changes between versions, so plugins can check what they can rely on.
- [ ] **Editor widgets.** The editor's own actions (move by word, kill the line, search history) as procs that key bindings can call, and a way to rebind keys the editor already uses.
- [ ] **Syntax highlighting.** A hook that gets the input and returns colored spans, which the editor draws as you type. A default that marks commands, Nim keywords and strings.
- [ ] **More host procs for plugins.** Plugins can't call C, so anything outside NimScript has to come from nish: terminal size, time, job information, and reading and writing the history.
- [ ] **Richer completion.** Descriptions next to candidates, a menu to move through them, and completers for common programs (`git`, `ssh` hosts, `make` targets) as plugins.

## Shell features

- [ ] **Input from Nim.** Pipe a Nim string into a command, for example `run("wc -l", input = text)`, without a temporary file.
- [ ] **Recursive globs.** `**/*.nim` matching through subdirectories.
- [ ] **A login shell.** What nish needs to be someone's login shell: a profile script for login sessions and a page on setting it up.

## Distribution

- [ ] **Release builds.** Binaries for macOS (arm64 and x86-64) and Linux on GitHub Releases for every tagged version.
- [ ] **Installing.** A Homebrew formula and an install script.

## Later

- **Startup time.** A shell starts in about 60 ms today, most of it compiling the `system` module. Caching the compiled state between runs could bring that down, but the compiler has no supported way to do it yet, so this waits until startup becomes a real problem.
- **Windows.** nish uses POSIX process groups and terminals throughout. Windows support would need its own process and console layer, so it is out of scope for now.

## Have a request?

Open an issue on [GitHub](https://github.com/playforge-coding/nish/issues) with what you tried and what happened. An input that reproduces the problem moves an item up the list faster than anything else.
