## Finds command lines in input and rewrites them into Nim.
##
## Input is Nim first. A line is a command only when its first word is not a
## Nim keyword or a symbol in scope but does name a program, as in `ls -la`,
## which becomes `run(@["ls", "-la"])`. Lines keep their indentation, so
## commands also work inside Nim blocks. `@(expr)` puts the value of a Nim
## expression into a command as one argument.

import std/strutils

type
  Resolver* = object
    isNimSymbol*: proc(name: string): bool
    isProgram*: proc(name: string): bool

  Word* = object
    text*: string
    isNim*: bool ## `text` is a Nim expression from `@(...)`

const
  nimKeywords = [
    "addr", "and", "as", "asm", "bind", "block", "break", "case", "cast", "concept",
    "const", "continue", "converter", "defer", "discard", "distinct", "div", "do",
    "elif", "else", "end", "enum", "except", "export", "finally", "for", "from", "func",
    "if", "import", "in", "include", "interface", "is", "isnot", "iterator", "let",
    "macro", "method", "mixin", "mod", "nil", "not", "notin", "object", "of", "or",
    "out", "proc", "ptr", "raise", "ref", "return", "shl", "shr", "static", "template",
    "try", "tuple", "type", "using", "var", "when", "while", "xor", "yield",
  ]
  # A first word directly followed by one of these is Nim: `ls(x)`, `ls.len`.
  nimFollowers = {'(', '[', '{', '.', '=', ':', ','}

proc isIdent(word: string): bool =
  word.len > 0 and word[0] in IdentStartChars and word.allCharsInSet(IdentChars)

proc skipWhile(s: string, chars: set[char], start: int): int =
  result = start
  while result < s.len and s[result] in chars:
    inc result

proc splitWords*(s: string): seq[Word] =
  ## Splits a command line into words the way a POSIX shell does for plain
  ## quoting: single quotes are literal, double quotes allow `\"` and `\\`,
  ## and a backslash outside quotes escapes the next character. A `#` that
  ## starts a word begins a comment, and `@(...)` that starts a word is Nim.
  result = @[]
  var word = ""
  var inWord = false
  var i = 0
  while i < s.len:
    let c = s[i]
    case c
    of Whitespace:
      if inWord:
        result.add Word(text: word)
        word = ""
        inWord = false
    of '@':
      if not inWord and i + 1 < s.len and s[i + 1] == '(':
        var depth = 0
        var j = i + 1
        while j < s.len:
          if s[j] == '(':
            inc depth
          elif s[j] == ')':
            dec depth
            if depth == 0:
              break
          inc j
        result.add Word(text: s[i + 2 ..< min(j, s.len)], isNim: true)
        i = j
      else:
        inWord = true
        word.add c
    of '\'':
      inWord = true
      inc i
      while i < s.len and s[i] != '\'':
        word.add s[i]
        inc i
    of '"':
      inWord = true
      inc i
      while i < s.len and s[i] != '"':
        if s[i] == '\\' and i + 1 < s.len and s[i + 1] in {'"', '\\'}:
          inc i
        word.add s[i]
        inc i
    of '\\':
      inWord = true
      if i + 1 < s.len:
        inc i
        word.add s[i]
    of '#':
      if inWord:
        word.add c
      else:
        break
    else:
      inWord = true
      word.add c
    inc i
  if inWord:
    result.add Word(text: word)

proc isCommandLine*(line: string, r: Resolver): bool =
  let rest = line.strip(trailing = false)
  if rest.len == 0 or rest[0] == '#':
    return false
  let word = rest[0 ..< skipWhile(rest, AllChars - Whitespace, 0)]
  if '/' in word:
    return r.isProgram(word)
  let ident = rest[0 ..< skipWhile(rest, IdentChars, 0)]
  if not isIdent(ident) or ident in nimKeywords or r.isNimSymbol(ident):
    return false
  if ident.len < rest.len and rest[ident.len] in nimFollowers:
    return false
  # `ls = 3` assigns, even with the space.
  let next = skipWhile(rest, Whitespace, ident.len)
  if next < rest.len and rest[next] == '=' and
      (next + 1 == rest.len or rest[next + 1] != '='):
    return false
  ident == word and r.isProgram(ident)

proc translateLine*(line: string, r: Resolver): string =
  if not isCommandLine(line, r):
    return line
  let indent = line.len - line.strip(trailing = false).len
  var args: seq[string] = @[]
  for word in splitWords(line):
    if word.isNim:
      args.add "$(" & word.text & ")"
    else:
      var lit = ""
      lit.addQuoted word.text
      args.add lit
  line[0 ..< indent] & "run(@[" & args.join(", ") & "])"

proc translate*(code: string, r: Resolver): string =
  ## Rewrites every command line in `code`, leaving lines inside triple
  ## quoted strings alone.
  var lines: seq[string] = @[]
  var inTriple = false
  for line in code.splitLines:
    lines.add(
      if inTriple:
        line
      else:
        translateLine(line, r)
    )
    if line.count("\"\"\"") mod 2 == 1:
      inTriple = not inTriple
  lines.join("\n")
