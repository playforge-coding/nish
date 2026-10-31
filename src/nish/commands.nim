## Shell command lines: finding them in input, rewriting them into Nim, and
## parsing them into pipelines.
##
## Input is Nim first. A line is a command only when its first word is not a
## Nim keyword or a symbol in scope but does name a program, as in `ls -la`,
## which becomes `run("ls -la")`. Lines keep their indentation, so commands
## also work inside Nim blocks. `@(expr)` puts the value of a Nim expression
## into a command; the rewriter replaces it with `splice` and passes the
## expression as an argument, and `nishapi.run` hands both to the host, which
## parses the line with `parseCommandLine` and runs it. Nothing here touches
## the file system, so the parser is the same at the prompt and in `sh"..."`.

import std/[sequtils, strutils]

type
  Resolver* = object
    isNimSymbol*: proc(name: string): bool ## Style insensitive, as Nim matches names.
    isExactNimSymbol*: proc(name: string): bool
      ## Only a symbol declared with exactly this spelling. Decides a name
      ## that is also a program: `mkdir` runs the program, `mkDir` is Nim.
      ## Falls back to `isNimSymbol` when nil.
    isProgram*: proc(name: string): bool

  Quote* = enum
    qNone ## bare: globs, `~` and `$VAR` expand
    qDouble ## only `$VAR` expands
    qSingle ## nothing expands

  Segment* = object
    text*: string
    quote*: Quote

  Word* = seq[Segment]

  RedirectKind* = enum
    rdWrite ## `>`
    rdAppend ## `>>`
    rdRead ## `<`
    rdDup ## `>&`: `target` is the descriptor to copy, as text

  Redirect* = object
    fd*: int
    kind*: RedirectKind
    target*: Word

  Command* = object
    words*: seq[Word]
    redirects*: seq[Redirect]

  Pipeline* = seq[Command]

  Chain* = enum
    chAlways ## `;`, or the first pipeline of the line
    chAnd ## `&&`
    chOr ## `||`

  Step* = object
    chain*: Chain ## how this pipeline depends on the one before it
    pipeline*: Pipeline
    background*: bool ## ended with `&`

  CommandLine* = seq[Step]

const
  splice* = '\0' ## stands for a `@(expr)` value inside a command line
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

# Parsing

type LineParser = object
  s: string
  i: int
  word: Word
  inWord: bool
  pendingRedirect: int ## index of the redirect waiting for its target, or -1
  command: Command
  pipeline: Pipeline
  chain: Chain
  background: bool
  line: CommandLine

proc fail(msg: string) =
  raise newException(ValueError, msg)

proc addText(p: var LineParser, text: string, quote: Quote) =
  if p.inWord and p.word.len > 0 and p.word[^1].quote == quote:
    p.word[^1].text.add text
  else:
    p.word.add Segment(text: text, quote: quote)
  p.inWord = true

proc finishWord(p: var LineParser) =
  if not p.inWord:
    return
  if p.pendingRedirect >= 0:
    p.command.redirects[p.pendingRedirect].target = p.word
    p.pendingRedirect = -1
  else:
    p.command.words.add p.word
  p.word = @[]
  p.inWord = false

proc finishCommand(p: var LineParser, before: string) =
  ## `before` names the operator that ends the command, or is empty at the
  ## end of the line.
  p.finishWord()
  if p.pendingRedirect >= 0:
    fail "missing file after redirect"
  if p.command.words.len == 0:
    if p.command.redirects.len > 0:
      fail "missing command before redirect"
    if p.pipeline.len > 0:
      fail "missing command after '|'"
    if before.len > 0 and before != ";":
      fail "missing command before '" & before & "'"
    return
  p.pipeline.add p.command
  p.command = Command()

proc finishPipeline(p: var LineParser, before: string, next: Chain) =
  p.finishCommand(before)
  if p.pipeline.len > 0:
    p.line.add Step(chain: p.chain, pipeline: p.pipeline, background: p.background)
    p.pipeline = @[]
    p.background = false
  elif before.len > 0 and before != ";":
    fail "missing command before '" & before & "'"
  elif before.len == 0 and p.chain != chAlways:
    fail "missing command after '" & (if p.chain == chAnd: "&&" else: "||") & "'"
  p.chain = next

proc readQuoted(p: var LineParser, quote: char) =
  ## `p.i` is on the opening quote.
  var text = ""
  inc p.i
  while p.i < p.s.len and p.s[p.i] != quote:
    if quote == '"' and p.s[p.i] == '\\' and p.i + 1 < p.s.len and
        p.s[p.i + 1] in {'"', '\\', '$'}:
      inc p.i
      if p.s[p.i] == '$':
        # A literal `$`: in a segment of its own that won't be expanded.
        if text.len > 0:
          p.addText(text, qDouble)
          text = ""
        p.addText("$", qSingle)
        inc p.i
        continue
    text.add p.s[p.i]
    inc p.i
  if p.i >= p.s.len:
    fail "missing closing " & quote
  inc p.i
  p.addText(text, if quote == '"': qDouble else: qSingle)

proc takeFd(p: var LineParser, default: int): int =
  ## A redirect's descriptor is the bare digits right before it, as in `2>`.
  if p.inWord and p.word.len == 1 and p.word[0].quote == qNone and
      p.word[0].text.allCharsInSet(Digits):
    result = parseInt(p.word[0].text)
    p.word = @[]
    p.inWord = false
  else:
    p.finishWord()
    result = default

proc readRedirect(p: var LineParser) =
  ## `p.i` is on `<` or `>`.
  let c = p.s[p.i]
  let fd = p.takeFd(if c == '<': 0 else: 1)
  if p.pendingRedirect >= 0:
    fail "missing file after redirect"
  inc p.i
  var r = Redirect(fd: fd, kind: if c == '<': rdRead else: rdWrite)
  if c == '>' and p.i < p.s.len and p.s[p.i] == '>':
    r.kind = rdAppend
    inc p.i
  elif c == '>' and p.i < p.s.len and p.s[p.i] == '&':
    inc p.i
    let start = p.i
    while p.i < p.s.len and p.s[p.i] in Digits:
      inc p.i
    if p.i == start:
      fail "missing descriptor after '>&'"
    r.kind = rdDup
    r.target = @[Segment(text: p.s[start ..< p.i], quote: qSingle)]
    p.command.redirects.add r
    return
  p.command.redirects.add r
  p.pendingRedirect = p.command.redirects.high

proc parseCommandLine*(s: string): CommandLine =
  ## Parses one line of shell syntax. Raises `ValueError` on bad syntax.
  var p = LineParser(s: s, pendingRedirect: -1)
  while p.i < p.s.len:
    let c = p.s[p.i]
    case c
    of ' ', '\t':
      p.finishWord()
      inc p.i
    of '\'', '"':
      p.readQuoted(c)
    of '\\':
      inc p.i
      if p.i < p.s.len:
        p.addText($p.s[p.i], qSingle)
        inc p.i
      else:
        p.addText("\\", qSingle)
    of '#':
      if p.inWord:
        p.addText("#", qNone)
        inc p.i
      else:
        break
    of '|':
      if p.i + 1 < p.s.len and p.s[p.i + 1] == '|':
        p.finishPipeline("||", chOr)
        inc p.i, 2
      else:
        p.finishCommand("|")
        inc p.i
    of '&':
      if p.i + 1 < p.s.len and p.s[p.i + 1] == '&':
        p.finishPipeline("&&", chAnd)
        inc p.i, 2
      else:
        p.background = true
        p.finishPipeline("&", chAlways)
        inc p.i
    of ';':
      p.finishPipeline(";", chAlways)
      inc p.i
    of '<', '>':
      p.readRedirect()
    else:
      p.addText($c, qNone)
      inc p.i
  p.finishPipeline("", chAlways)
  p.line

proc countSplices*(pipeline: Pipeline): int =
  ## How many splice values the pipeline consumes, to skip them when `&&` or
  ## `||` skips the pipeline itself.
  result = 0
  for cmd in pipeline:
    for w in cmd.words:
      for seg in w:
        result += seg.text.count(splice)
    for r in cmd.redirects:
      for seg in r.target:
        result += seg.text.count(splice)

# Finding and rewriting command lines

const builtins = ["cd", "exit", "jobs", "fg", "bg"]

proc jobId(args: string): string =
  ## `fg 2` and `fg %2` both mean job 2.
  args.strip(trailing = false, chars = {'%'})

proc skipWhile(s: string, chars: set[char], start: int): int =
  result = start
  while result < s.len and s[result] in chars:
    inc result

proc isIdent(word: string): bool =
  word.len > 0 and word[0] in IdentStartChars and word.allCharsInSet(IdentChars)

proc builtinTakesLine(name, args: string, r: Resolver): bool =
  ## Whether `name args` is the builtin's command form rather than Nim. Nim
  ## still wins when the argument is a string literal, a parenthesis or a
  ## symbol in scope: `cd "/tmp"`, `cd(dir)` and `cd dir` are Nim.
  case name
  of "cd":
    if args.len == 0:
      return true
    if args[0] in {'"', '('}:
      return false
    let ident = args[0 ..< skipWhile(args, IdentChars, 0)]
    let wholeWord = ident.len == args.len or args[ident.len] in Whitespace
    not (isIdent(ident) and wholeWord and r.isNimSymbol(ident))
  of "exit":
    args.len == 0 or args.allCharsInSet(Digits)
  of "jobs":
    args.len == 0
  of "fg", "bg":
    args.len == 0 or jobId(args).allCharsInSet(Digits)
  else:
    false

iterator unquoted(s: string): tuple[i: int, depth: int] =
  ## Positions outside quotes and backslash escapes, with the bracket depth
  ## at each.
  var quote = ' '
  var depth = 0
  var i = 0
  while i < s.len:
    let c = s[i]
    if quote != ' ':
      if c == quote:
        quote = ' '
      elif c == '\\' and quote == '"':
        inc i
    elif c in {'\'', '"'}:
      quote = c
    elif c == '\\':
      inc i # the escaped character is text, not syntax
    else:
      if c in {'(', '[', '{'}:
        inc depth
      elif c in {')', ']', '}'}:
        dec depth
      yield (i, depth)
    inc i

proc startsComment(s: string, i: int): bool =
  ## A `#` at the start of a word begins a comment in Nim and in a shell.
  s[i] == '#' and (i == 0 or s[i - 1] in Whitespace)

proc hasShellOperator(s: string): bool =
  ## `&&`, `||`, `>>` and `>&` are never Nim, so a line holding one outside
  ## quotes is a command whatever its first word is. (`2>` is not on the
  ## list: `5>x` is a Nim comparison.)
  for (i, _) in unquoted(s):
    if s.startsComment(i):
      return false
    if s[i] in {'&', '|', '>'} and i + 1 < s.len and s[i + 1] in {'&', '|', '>'} and
        s[i .. i + 1] in ["&&", "||", ">>", ">&"]:
      return true
  false

proc splitStatements*(line: string): seq[string] =
  ## Splits at `;` outside quotes and brackets, which separates statements in
  ## Nim as well as commands in a shell, so each part can be either.
  result = @[]
  var start = 0
  for (i, depth) in unquoted(line):
    if line[i] == ';' and depth == 0:
      result.add line[start ..< i]
      start = i + 1
  result.add line[start .. ^1]

proc isCommandPart(part: string, r: Resolver): bool =
  let rest = part.strip(trailing = false)
  if rest.len == 0 or rest[0] == '#':
    return false
  if hasShellOperator(rest):
    return true
  let word = rest[0 ..< skipWhile(rest, AllChars - Whitespace, 0)]
  if '/' in word:
    return r.isProgram(word)
  let ident = rest[0 ..< skipWhile(rest, IdentChars, 0)]
  if not isIdent(ident) or ident in nimKeywords:
    return false
  if ident.len < rest.len and rest[ident.len] in nimFollowers:
    return false
  if ident in builtins:
    return builtinTakesLine(ident, rest[ident.len .. ^1].strip, r)
  let nim = if r.isExactNimSymbol != nil: r.isExactNimSymbol else: r.isNimSymbol
  if nim(ident):
    return false
  # `ls = 3` assigns, even with the space.
  let next = skipWhile(rest, Whitespace, ident.len)
  if next < rest.len and rest[next] == '=' and
      (next + 1 == rest.len or rest[next + 1] != '='):
    return false
  ident == word and r.isProgram(ident)

proc isCommandLine*(line: string, r: Resolver): bool =
  ## Whether the line starts with a command. A leading `!` makes the whole
  ## line one; otherwise the part before the first `;` decides.
  let rest = line.strip(trailing = false)
  (rest.len > 0 and rest[0] == '!') or isCommandPart(splitStatements(rest)[0], r)

proc unknownCommand*(line: string, r: Resolver): string =
  ## The first word of a line that is shaped like a command but names no
  ## program, or "". Such a line would otherwise get the compiler's
  ## "undeclared identifier", when "command not found" is what happened.
  ## The shape: a bare word, possibly with hyphens, that is no Nim symbol,
  ## followed by nothing or by something that starts a shell argument rather
  ## than a Nim operator.
  let rest = line.strip
  if rest.len == 0 or rest[0] notin IdentStartChars:
    return ""
  let word = rest[0 ..< skipWhile(rest, IdentChars + {'-'}, 0)]
  let ident = rest[0 ..< skipWhile(rest, IdentChars, 0)]
  if word in nimKeywords or word in builtins or r.isNimSymbol(word) or r.isProgram(word):
    return ""
  if ident != word and r.isNimSymbol(ident): # `a-b` with a Nim `a`
    return ""
  let args = rest[word.len .. ^1]
  if args.len == 0:
    return word
  if args[0] notin Whitespace:
    return ""
  let a = args.strip
  if a.len == 0:
    return word
  let argStart =
    a[0] in IdentChars or a[0] in {'/', '.', '~', '$', '"', '\'', '@'} or
    (a[0] == '-' and a.len > 1 and a[1] in Letters + {'-'})
  if argStart: word else: ""

# Where in Nim a line is

type LineContext* = object
  nimOnly*: bool
    ## Inside a declaration section, an open bracket, a continued expression
    ## or a `#[ ]#` comment: never a command.
  locals*: seq[string]
    ## Names declared in the enclosing blocks of this input (parameters,
    ## `result`, loop variables, `let` and `var`), which the session's scope
    ## doesn't know about yet.

const
  routineWords =
    ["proc", "func", "method", "iterator", "converter", "template", "macro"]
  sectionWords = ["type", "const", "let", "var", "using"]

proc endsIn(s: string, chars: set[char]): bool =
  s.len > 0 and s[^1] in chars

proc cleanName(s: string): string =
  ## `x*`, `` `x` `` and `x {.pragma.}` all declare `x`.
  result = s.strip
  let stop = skipWhile(result, IdentChars + {'`'}, 0)
  result = result[0 ..< stop].strip(chars = {'`'})

proc paramNames(header: string): seq[string] =
  ## The parameter names of a routine header, as in `proc f(a, b: int; c = 1)`.
  result = @[]
  let open = header.find('(')
  if open < 0:
    return
  # Split at commas and semicolons outside brackets, so `cb: proc(x: int)`
  # stays one parameter; each part is a name, then maybe `: type` or `= x`.
  var depth = 0
  var part = ""
  var parts: seq[string] = @[]
  for i in open + 1 ..< header.len:
    let c = header[i]
    if c in {'(', '[', '{'}:
      inc depth
    elif c in {')', ']', '}'}:
      if depth == 0:
        break
      dec depth
    elif c in {',', ';'} and depth == 0:
      parts.add part
      part = ""
      continue
    part.add c
  parts.add part
  for p in parts:
    var name = p
    for sep in [':', '=']:
      let k = name.find(sep)
      if k >= 0:
        name = name[0 ..< k]
    let n = cleanName(name)
    if n.len > 0:
      result.add n

proc findWord(code, word: string, start = 0): int =
  ## The first `word` in `code` at or after `start` that stands on its own,
  ## or -1.
  var k = code.find(word, start)
  while k >= 0:
    let before = k == 0 or code[k - 1] notin IdentChars
    let after = k + word.len >= code.len or code[k + word.len] notin IdentChars
    if before and after:
      return k
    k = code.find(word, k + 1)
  -1

proc anonymousRoutine(code: string): int =
  ## Where an anonymous `proc(...)`, `func(...)` or `iterator(...)` starts in
  ## `code`, or -1. The earliest one counts, so a proc type among its
  ## parameters doesn't, and one in a type position (`h: proc(x: int)`) is a
  ## type, not a body.
  result = -1
  for word in ["proc", "func", "iterator"]:
    var k = findWord(code, word)
    while k >= 0:
      let open = skipWhile(code, Whitespace, k + word.len)
      var before = k - 1
      while before >= 0 and code[before] in Whitespace:
        dec before
      if open < code.len and code[open] == '(' and (before < 0 or code[before] != ':'):
        if result < 0 or k < result:
          result = k
        break
      k = findWord(code, word, k + 1)

proc declaredNames(stripped: string): seq[string] =
  ## Names a statement declares: `let a = 1`, `var (x, y) = ...`, `for a, b in`.
  result = @[]
  let first = stripped[0 ..< skipWhile(stripped, IdentChars, 0)]
  var rest = stripped[first.len .. ^1]
  case first
  of "let", "var", "const":
    for sep in ['=', ':']:
      let k = rest.find(sep)
      if k >= 0:
        rest = rest[0 ..< k]
    for name in rest.strip(chars = Whitespace + {'(', ')'}).split(','):
      let n = cleanName(name.strip(chars = Whitespace + {'(', ')'}))
      if n.len > 0:
        result.add n
  of "for":
    let k = rest.find(" in ")
    if k >= 0:
      for name in rest[0 ..< k].strip(chars = Whitespace + {'(', ')'}).split(','):
        let n = cleanName(name.strip(chars = Whitespace + {'(', ')'}))
        if n.len > 0:
          result.add n
  else:
    discard

proc lineContexts*(
    code: string, isCommand: proc(line: string, locals: seq[string]): bool = nil
): seq[LineContext] =
  ## A `LineContext` for every line of `code`, from its indentation, block
  ## openers and brackets. A heuristic, not a parser, but it only has to tell
  ## statements from everything else. `isCommand` keeps a command line that
  ## ends in `/` or `-` from looking like a continued expression.
  type Block = object
    indent: int
    declaration: bool
    locals: seq[string]

  result = @[]
  var stack: seq[Block] = @[Block(indent: -1)]
  var depth = 0 ## open brackets carried over from earlier lines
  var continued = false ## the previous line left an expression open
  var inTriple = false
  var commentDepth = 0 ## inside `#[ ]#`
  for line in code.splitLines:
    let stripped = line.strip
    let indent = line.len - line.strip(trailing = false).len
    var ctx = LineContext()
    if inTriple or commentDepth > 0 or depth > 0 or continued or stripped.len == 0 or
        stripped.startsWith("#"):
      ctx.nimOnly = true
    else:
      while stack.len > 1 and stack[^1].indent >= indent:
        discard stack.pop
      for b in stack:
        if b.declaration:
          ctx.nimOnly = true
        ctx.locals.add b.locals
    result.add ctx

    # What this line changes for the ones after it.
    let wasNimOnly = ctx.nimOnly and not (stripped.len == 0 or stripped.startsWith("#"))
    inc commentDepth, line.count("#[")
    dec commentDepth, line.count("]#")
    commentDepth = max(commentDepth, 0)
    if line.count("\"\"\"") mod 2 == 1:
      inTriple = not inTriple
    if inTriple or wasNimOnly and (depth > 0 or continued):
      # Still inside something; only the bracket count can end it.
      for (i, d) in unquoted(line):
        if line.startsComment(i):
          break
        if line[i] in {'(', '[', '{'}:
          inc depth
        elif line[i] in {')', ']', '}'}:
          depth = max(depth - 1, 0)
      continued =
        depth == 0 and not inTriple and line.strip.endsIn({',', '(', '[', '{'})
      continue
    if stripped.len == 0 or stripped.startsWith("#"):
      continue
    let first = stripped[0 ..< skipWhile(stripped, IdentChars, 0)]
    var lineDepth = 0
    var code = "" ## the line without string contents and comment, for searching
    var commentAt = line.len
    for (i, d) in unquoted(line):
      if line.startsComment(i):
        commentAt = i
        break
      lineDepth = d
      code.add line[i]
    depth = max(lineDepth, 0)
    # The real end of the line: `var s = ""` ends in a string, not in `=`.
    let tail = line[0 ..< commentAt].strip(leading = false)
    let section = first in sectionWords and stripped == first or first == "type"
    if first in ["let", "var", "const"] and not section:
      stack[^1].locals.add declaredNames(stripped)
    elif first in routineWords:
      let name = cleanName(stripped[first.len .. ^1])
      if name.len > 0:
        stack[^1].locals.add name # callable on the next lines, recursion too
    # Where a routine's header starts, if this line opens its body: a named
    # one (`proc f(x: int) =`), or an anonymous one (`hooks.add proc(x: int) =`,
    # `let f = proc(x: int): int =`).
    var header = -1
    if first in routineWords and tail.endsWith("="):
      header = code.len - code.strip(trailing = false).len
    elif depth == 0 and tail.endsWith("="):
      header = anonymousRoutine(code)
    if header >= 0:
      stack.add Block(
        indent: indent, locals: paramNames(code[header .. ^1]) & @["result"]
      )
      continued = false
    elif section:
      stack.add Block(indent: indent, declaration: true)
      continued = false
    elif first in sectionWords and tail.endsIn({'=', ':'}):
      continued = depth == 0 and tail.endsIn({'=', ','})
    elif depth == 0 and tail.endsWith(":"):
      # `for a, b in xs:` declares its loop variables, `hooks.add do (x: int):`
      # its parameters.
      let doAt = findWord(code, "do")
      let locals =
        if doAt >= 0:
          paramNames(code[doAt .. ^1])
        else:
          declaredNames(stripped)
      stack.add Block(indent: indent, locals: locals)
      continued = false
    else:
      if isCommand != nil and isCommand(line, ctx.locals):
        depth = 0
        continued = false
      else:
        continued =
          depth == 0 and tail.len > 0 and
          tail[^1] in {'=', ',', '+', '-', '*', '/', '&', '|', '<', '>', '.', '('}

proc withLocals(r: Resolver, locals: seq[string]): Resolver =
  if locals.len == 0:
    return r
  let normalized = locals.mapIt(it.nimIdentNormalize)
  Resolver(
    isNimSymbol: proc(name: string): bool =
      name.nimIdentNormalize in normalized or r.isNimSymbol(name),
    isExactNimSymbol: proc(name: string): bool =
      name in locals or (
        if r.isExactNimSymbol != nil: r.isExactNimSymbol(name)
        else: r.isNimSymbol(name)
      ),
    isProgram: r.isProgram,
  )

proc contextsFor(code: string, r: Resolver): seq[LineContext] =
  lineContexts(
    code,
    proc(line: string, locals: seq[string]): bool =
      isCommandLine(line, r.withLocals(locals)),
  )

proc findUnknownCommand*(code: string, r: Resolver): string =
  ## `unknownCommand` over every statement line of an input.
  let lines = code.splitLines
  let contexts = contextsFor(code, r)
  for i, line in lines:
    if not contexts[i].nimOnly:
      let word = unknownCommand(line, r.withLocals(contexts[i].locals))
      if word.len > 0:
        return word
  ""

proc skipCharLiteral(s: string, j: int): int =
  ## The index of the closing quote of the character literal at `j`, or `j`
  ## if there is none.
  if j + 2 < s.len and s[j + 1] == '\\':
    let close = s.find('\'', j + 2)
    if close > 0: close else: j
  elif j + 2 < s.len and s[j + 2] == '\'':
    j + 2
  else:
    j

proc extractSplices*(line: string): tuple[line: string, exprs: seq[string]] =
  ## Replaces each `@(expr)` outside single quotes with `splice` and returns
  ## the expressions in order. `\@(` stays literal.
  result = (line: "", exprs: @[])
  var quote = ' '
  var i = 0
  while i < line.len:
    let c = line[i]
    if quote == '\'':
      if c == '\'':
        quote = ' '
      result.line.add c
    elif c == '\\' and i + 1 < line.len:
      result.line.add c
      inc i
      result.line.add line[i]
    elif quote == '"' and c == '"':
      quote = ' '
      result.line.add c
    elif quote == ' ' and c in {'\'', '"'}:
      quote = c
      result.line.add c
    elif c == '@' and i + 1 < line.len and line[i + 1] == '(':
      var depth = 0
      var j = i + 1
      var inString = false
      while j < line.len:
        if inString:
          if line[j] == '\\':
            inc j
          elif line[j] == '"':
            inString = false
        elif line[j] == '"':
          inString = true
        elif line[j] == '\'':
          j = skipCharLiteral(line, j)
        elif line[j] == '(':
          inc depth
        elif line[j] == ')':
          dec depth
          if depth == 0:
            break
        inc j
      if j >= line.len:
        fail "missing closing parenthesis in @(...)"
      result.exprs.add line[i + 2 ..< j]
      result.line.add splice
      i = j
    else:
      result.line.add c
    inc i

proc nimCall(name, line: string, exprs: seq[string]): string =
  var lit = ""
  lit.addQuoted line
  result = name & "(" & lit
  for e in exprs:
    result.add ", " & e
  result.add ")"

proc translatePart(part: string, r: Resolver): string =
  if not isCommandPart(part, r):
    return part
  let rest = part.strip
  let ident = rest[0 ..< skipWhile(rest, IdentChars, 0)]
  let word = rest[0 ..< skipWhile(rest, AllChars - Whitespace, 0)]
  let (cmd, exprs) = extractSplices(rest)
  # `cd/tool` is a program, not the builtin.
  case (if word == ident: ident else: "")
  of "cd":
    let args = cmd[ident.len .. ^1].strip
    if args.len == 0:
      "cd(getEnv(\"HOME\"))"
    else:
      "cd(" & nimCall("word", args, exprs) & ")"
  of "exit":
    let args = cmd[ident.len .. ^1].strip
    "quit(" & (if args.len == 0: "lastStatus" else: args) & ")"
  of "jobs":
    "jobs()"
  of "fg", "bg":
    ident & "(" & jobId(cmd[ident.len .. ^1].strip) & ")"
  else:
    nimCall("run", cmd, exprs)

proc translateLine*(line: string, r: Resolver): string =
  let rest = line.strip(trailing = false)
  let indent = line[0 ..< line.len - rest.len]
  if rest.len > 0 and rest[0] == '!':
    let (cmd, exprs) = extractSplices(rest[1 .. ^1].strip)
    return indent & nimCall("run", cmd, exprs)
  let parts = splitStatements(rest)
  if parts.len == 1:
    return indent & translatePart(rest, r)
  var translated: seq[string] = @[]
  for part in parts:
    translated.add translatePart(part, r).strip
  indent & translated.join("; ")

proc translate*(code: string, r: Resolver): string =
  ## Rewrites every command line in `code`. Only statement lines can be
  ## commands, and names declared earlier in the input count as Nim.
  let contexts = contextsFor(code, r)
  var lines: seq[string] = @[]
  for i, line in code.splitLines.toSeq:
    lines.add(
      if contexts[i].nimOnly:
        line
      else:
        translateLine(line, r.withLocals(contexts[i].locals))
    )
  lines.join("\n")
