# API reference

nish adds these names to NimScript. They are in scope at the prompt, in scripts and in `init.nims`; a plugin module gets them with `import nishapi`. The [NimScript API](https://nim-lang.org/docs/nimscript.html) (`cd`, `getEnv`, `listFiles`, `exec` and so on) is available as well.

## Running commands

`proc run(line: string, splices: varargs[...]): int {.discardable.}`
:   Runs a command line attached to the terminal and returns the exit status of its last command, which also goes into `lastStatus`. The line uses the [command syntax](language.md#command-syntax). Each NUL character (`\0`) in `line` takes the next value from `splices`; command lines at the prompt become calls like this, with `@(expr)` turned into `\0` and an extra argument.

`proc sh(line: string, splices: varargs[...]): string`
:   Runs a command line like `run`, but returns what it wrote to standard output, without trailing newlines. Sets `lastStatus`. A captured command can't be suspended with Ctrl-Z.

`proc words(line: string, splices: varargs[...]): seq[string]`
:   The words of a single command after quoting and expansion (globs, `~`, `$VAR`, aliases), without running anything. `words("*.nim")` lists the matching files.

`proc word(line: string, splices: varargs[...]): string`
:   Like `words`, for a line that must expand to exactly one word. Raises `ValueError` otherwise.

`var lastStatus: int`
:   The exit status of the last command. A failed input sets it to 1, and a command that wasn't found to 127.

`proc alias(name, line: string)`
:   Makes `name` stand for the start of a command line. See [Aliases](customizing.md#aliases).

Values passed as `splices` are converted with `toArgs`: a string, number, `bool` or `char` becomes one argument, and an array or sequence one argument per element.

## Jobs

`proc jobs()`
:   Lists the background and stopped jobs.

`proc fg(id = 0): int {.discardable.}`
:   Brings job `id` to the foreground and waits for it, returning its status and setting `lastStatus`. Without an id, the most recent job, stopped ones first.

`proc bg(id = 0)`
:   Lets a stopped job continue in the background.

## Hooks

These are variables you set or add to, usually in `init.nims`. See [Customizing](customizing.md#hooks).

`var prompt: proc(): string`
:   Returns the prompt. The default shows the current directory with `~` for home.

`var continuationPrompt: proc(): string`
:   Returns the prompt for the following lines of a multi-line input. The default is `  ... `.

`var onPreCommand: seq[proc(line: string)]`
:   Run with each input at the prompt before it is evaluated.

`var onCommandDone: seq[proc(line: string, status: int)]`
:   Run after each input at the prompt, with `lastStatus`.

`var onDirChange: seq[proc(dir: string)]`
:   Run before a prompt when the current directory changed.

`type Completer = proc(line, word: string): seq[string]`
:   Gets the line up to the cursor and the word being completed; returns replacements for the word.

`var completers: seq[Completer]`
:   All asked on Tab, with their answers combined. It starts with the default completer.

## Key bindings

`proc bindKey(key: string, action: proc())`
:   Runs `action` when `key` is pressed at the prompt, instead of the editor's own action. Binding a key again replaces the earlier binding. See [Key bindings](customizing.md#key-bindings) for key names.

`proc editorText(): string`
:   The input being edited.

`proc editorCursor(): int`
:   The cursor's byte offset in `editorText()`.

`proc editorSetText(text: string, cursor: int)`
:   Replaces the input and puts the cursor at `cursor`.

`proc editorInsert(s: string)`
:   Inserts `s` at the cursor.

The four editor procs only do something inside a key binding; elsewhere they read an empty input and change nothing.

## Helpers

`proc tildePath(path: string): string`
:   `path` with the home directory written as `~`.
