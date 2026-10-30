## The line editor: raw terminal input, a multi-line buffer, history and
## completion.
##
## The terminal is switched into raw mode only while a line is read, with
## `TCSADRAIN`, so typed-ahead or pasted input is never thrown away (which
## is what linenoise did). Bracketed paste is on, so a pasted block becomes
## one input however many newlines it has. Rendering redraws the whole
## input every time and keeps track of the row the cursor is on, so it can
## get back to the top of its area, also when lines wrap.

import std/[os, posix, strutils, termios, terminal, unicode]

type
  Key* = object
    name*: string ## "enter", "ctrl-a", "alt-f", "up", "paste", "char", ...
    text*: string ## the character for "char", the pasted text for "paste"

  Editor* = ref object
    complete*: proc(line: string): seq[string]
      ## Replacements for the text before the cursor on the current line.
    needsMore*: proc(text: string): bool
      ## Whether Enter should add a line instead of accepting the input.
    userKey*: proc(key: string): bool
      ## A key binding made from Nim; returns whether it handled the key.
    history: seq[string]
    historyFile: string
    # State of the input being edited
    text: string
    cursor: int ## byte offset into `text`
    prompt, continuation: string
    cursorRow: int ## row of the drawn area the cursor is on
    killed: string
    historyIndex: int
    savedText: string ## what was typed before browsing the history

const
  wordChars = Letters + Digits + {'_'}
  maxHistory = 10000

var active*: Editor ## the editor reading input right now, for key bindings

# Terminal

var original: Termios
var rawMode = false

proc enableRaw() =
  if rawMode or tcGetAttr(0, addr original) != 0:
    return
  var raw = original
  raw.c_iflag = raw.c_iflag and not (BRKINT or ICRNL or INPCK or ISTRIP or IXON)
  raw.c_lflag = raw.c_lflag and not (ECHO or ICANON or IEXTEN or ISIG)
  raw.c_cflag = raw.c_cflag or CS8
  raw.c_cc[VMIN] = char(1)
  raw.c_cc[VTIME] = char(0)
  discard tcSetAttr(0, TCSADRAIN, addr raw)
  rawMode = true
  stdout.write "\e[?2004h" # bracketed paste
  stdout.flushFile

proc disableRaw() =
  if not rawMode:
    return
  stdout.write "\e[?2004l"
  stdout.flushFile
  discard tcSetAttr(0, TCSADRAIN, addr original)
  rawMode = false

proc width(): int =
  let w = terminalWidth()
  if w <= 0: 80 else: w

# Keys

proc readByte(timeoutMs = -1): int =
  ## The next input byte, -1 on timeout and -2 at end of input.
  if timeoutMs >= 0:
    var fds: TFdSet
    FD_ZERO(fds)
    FD_SET(0, fds)
    var tv = Timeval(
      tv_sec: Time(timeoutMs div 1000), tv_usec: Suseconds((timeoutMs mod 1000) * 1000)
    )
    if select(1, addr fds, nil, nil, addr tv) <= 0:
      return -1
  var c: char
  while true:
    let n = posix.read(0, addr c, 1)
    if n == 1:
      return ord(c)
    if n == 0 or errno != EINTR:
      return -2

proc csiName(params: string, final: char): string =
  ## Names for `ESC [ params final` sequences.
  let parts = params.split(';')
  let modifier =
    if parts.len > 1:
      parseInt(parts[1])
    else:
      1
  let base =
    case final
    of 'A':
      "up"
    of 'B':
      "down"
    of 'C':
      "right"
    of 'D':
      "left"
    of 'H':
      "home"
    of 'F':
      "end"
    of '~':
      case parts[0]
      of "1", "7": "home"
      of "4", "8": "end"
      of "3": "delete"
      of "5": "pageup"
      of "6": "pagedown"
      else: "unknown"
    else:
      "unknown"
  case modifier
  of 2:
    "shift-" & base
  of 3:
    "alt-" & base
  of 5:
    "ctrl-" & base
  else:
    base

proc readPaste(): string =
  ## Everything up to the end-of-paste sequence.
  result = ""
  const stop = "\e[201~"
  while not result.endsWith(stop):
    let b = readByte()
    if b < 0:
      break
    result.add chr(b)
  if result.endsWith(stop):
    result.setLen(result.len - stop.len)
  result = result.replace("\r\n", "\n").replace('\r', '\n')

proc readKey*(): Key =
  let b = readByte()
  if b == -2:
    return Key(name: "eof")
  case b
  of 27:
    let next = readByte(30)
    if next < 0:
      return Key(name: "esc")
    if next == ord('['):
      var params = ""
      while true:
        let c = readByte(30)
        if c < 0:
          return Key(name: "esc")
        if chr(c) in Digits or chr(c) == ';':
          params.add chr(c)
        else:
          if params == "200" and chr(c) == '~':
            return Key(name: "paste", text: readPaste())
          return Key(name: csiName(params, chr(c)))
    if next == ord('O'):
      let c = readByte(30)
      if c < 0:
        return Key(name: "esc")
      return Key(name: csiName("", chr(c)))
    if next == 13:
      return Key(name: "alt-enter")
    if next == 127 or next == 8:
      return Key(name: "alt-backspace")
    return Key(name: "alt-" & $chr(next).toLowerAscii)
  of 13:
    Key(name: "enter")
  of 10:
    Key(name: "ctrl-j")
  of 9:
    Key(name: "tab")
  of 127, 8:
    Key(name: "backspace")
  of 1 .. 7, 11, 12, 14 .. 26:
    Key(name: "ctrl-" & $chr(ord('a') + b - 1))
  of 0, 28 .. 31:
    Key(name: "unknown")
  else:
    var text = $chr(b)
    # The rest of a UTF-8 sequence.
    let more =
      if b >= 0xF0:
        3
      elif b >= 0xE0:
        2
      elif b >= 0xC0:
        1
      else:
        0
    for _ in 0 ..< more:
      let c = readByte(30)
      if c < 0:
        break
      text.add chr(c)
    Key(name: "char", text: text)

# Rendering

proc displayWidth(s: string): int =
  ## Characters on screen: color codes and other escape sequences count 0.
  result = 0
  var i = 0
  while i < s.len:
    if s[i] == '\e':
      inc i
      if i < s.len and s[i] == '[':
        inc i
        while i < s.len and s[i] notin {'@' .. '~'}:
          inc i
      inc i
    else:
      result += 1
      i += max(1, s.runeLenAt(i))

proc cursorLine(e: Editor): tuple[line, column: int] =
  ## The cursor's line and byte column within `text`.
  var line = 0
  var start = 0
  for i, c in e.text:
    if i >= e.cursor:
      break
    if c == '\n':
      inc line
      start = i + 1
  (line, e.cursor - start)

proc render(e: Editor, prompt = "", text = "", cursor = -1) =
  ## Redraws the input. The arguments override the editor's own for the
  ## history search display.
  let prompt = if prompt.len > 0: prompt else: e.prompt
  let text = if cursor >= 0: text else: e.text
  let cursor = if cursor >= 0: cursor else: e.cursor
  let w = width()
  var screen = "\r"
  if e.cursorRow > 0:
    screen.add "\e[" & $e.cursorRow & "A"
  screen.add "\e[J"
  let promptLines = prompt.split('\n')
  let textLines = text.split('\n')
  var pieces: seq[tuple[prefix, body: string]] = @[]
  for i in 0 ..< promptLines.high:
    pieces.add (promptLines[i], "")
  for i, line in textLines:
    let prefix =
      if i == 0:
        promptLines[^1]
      else:
        e.continuation
    pieces.add (prefix, line)
  var cursorPiece = promptLines.high
  var cursorByte = cursor
  for line in textLines:
    if cursorByte <= line.len:
      break
    cursorByte -= line.len + 1
    inc cursorPiece
  var row = 0
  var cursorR, cursorC = 0
  var endRow, endCol = 0
  for i, piece in pieces:
    screen.add piece.prefix & piece.body
    let prefixWidth = displayWidth(piece.prefix)
    let lineWidth = prefixWidth + piece.body.runeLen
    let full = lineWidth > 0 and lineWidth mod w == 0
    # A line that exactly fills its rows leaves the terminal waiting to
    # wrap; moving on explicitly keeps our row count and the terminal's in
    # step.
    if i < pieces.high or full:
      screen.add "\r\n"
    let rows =
      if full:
        lineWidth div w
      else:
        lineWidth div w + 1
    if i == cursorPiece:
      let before = prefixWidth + piece.body[0 ..< cursorByte].runeLen
      cursorR = row + before div w
      cursorC = before mod w
    if i == pieces.high:
      if full:
        endRow = row + rows
        endCol = 0
      else:
        endRow = row + lineWidth div w
        endCol = lineWidth mod w
    row += rows
  if endRow > cursorR:
    screen.add "\e[" & $(endRow - cursorR) & "A"
  screen.add "\r"
  if cursorC > 0:
    screen.add "\e[" & $cursorC & "C"
  e.cursorRow = cursorR
  stdout.write screen
  stdout.flushFile

proc moveBelow(e: Editor) =
  ## Puts the terminal cursor on a fresh line after the input, for output.
  e.render()
  let w = width()
  var rows = 0
  let promptLines = e.prompt.split('\n')
  for i in 0 ..< promptLines.high:
    rows += displayWidth(promptLines[i]) div w + 1
  let lines = e.text.split('\n')
  for i, line in lines:
    let lw =
      displayWidth(
        if i == 0:
          promptLines[^1]
        else:
          e.continuation
      ) + line.runeLen
    rows += (if lw > 0 and lw mod w == 0: lw div w
    else: lw div w + 1)
  if rows - 1 > e.cursorRow:
    stdout.write "\e[" & $(rows - 1 - e.cursorRow) & "B"
  stdout.write "\r\n"
  stdout.flushFile
  e.cursorRow = 0

# History

proc encodeEntry(s: string): string =
  s.replace("\\", "\\\\").replace("\n", "\\n")

proc decodeEntry(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      inc i
      result.add(
        if s[i] == 'n':
          '\n'
        else:
          s[i]
      )
    else:
      result.add s[i]
    inc i

proc loadHistory(e: Editor) =
  if fileExists(e.historyFile):
    for line in readFile(e.historyFile).splitLines:
      if line.len > 0:
        e.history.add decodeEntry(line)

proc addHistory*(e: Editor, entry: string) =
  if entry.strip.len == 0 or (e.history.len > 0 and e.history[^1] == entry):
    return
  e.history.add entry
  if e.history.len > maxHistory:
    e.history = e.history[^maxHistory .. ^1]
  if e.historyFile.len > 0:
    try:
      createDir(e.historyFile.parentDir)
      let f = open(e.historyFile, fmAppend)
      f.writeLine encodeEntry(entry)
      f.close
    except IOError, OSError:
      discard "history is a convenience"

proc newEditor*(historyFile: string): Editor =
  result = Editor(historyFile: historyFile, history: @[])
  result.loadHistory()

# Editing

proc insert(e: Editor, s: string) =
  e.text.insert(s, e.cursor)
  e.cursor += s.len

proc lineBounds(e: Editor): tuple[start, stop: int] =
  ## Byte range of the line the cursor is on, without its newline.
  var start = e.cursor
  while start > 0 and e.text[start - 1] != '\n':
    dec start
  var stop = e.cursor
  while stop < e.text.len and e.text[stop] != '\n':
    inc stop
  (start, stop)

proc prevRune(e: Editor, pos: int): int =
  result = pos
  if result > 0:
    dec result
    while result > 0 and (ord(e.text[result]) and 0xC0) == 0x80:
      dec result

proc nextRune(e: Editor, pos: int): int =
  if pos >= e.text.len:
    pos
  else:
    pos + max(1, e.text.runeLenAt(pos))

proc wordStart(e: Editor): int =
  result = e.cursor
  while result > 0 and e.text[result - 1] notin wordChars:
    dec result
  while result > 0 and e.text[result - 1] in wordChars:
    dec result

proc wordEnd(e: Editor): int =
  result = e.cursor
  while result < e.text.len and e.text[result] notin wordChars:
    inc result
  while result < e.text.len and e.text[result] in wordChars:
    inc result

proc deleteRange(e: Editor, a, b: int) =
  ## Removes `a ..< b`, keeping it for Ctrl-Y. `strutils.delete` raises on
  ## an empty range, so nothing to delete means nothing to do.
  if a >= b:
    return
  e.killed = e.text[a ..< b]
  e.text.delete(a ..< b)
  e.cursor = a

proc moveLine(e: Editor, delta: int): bool =
  ## Moves the cursor to the line above or below, keeping the column.
  let (line, column) = e.cursorLine
  let lines = e.text.split('\n')
  let target = line + delta
  if target < 0 or target >= lines.len:
    return false
  var offset = 0
  for i in 0 ..< target:
    offset += lines[i].len + 1
  e.cursor = offset + min(column, lines[target].len)
  true

proc useHistory(e: Editor, index: int) =
  if index < 0 or index > e.history.len:
    return
  if e.historyIndex == e.history.len:
    e.savedText = e.text
  e.historyIndex = index
  e.text =
    if index == e.history.len:
      e.savedText
    else:
      e.history[index]
  e.cursor = e.text.len

proc autoIndent(e: Editor): string =
  let (start, stop) = e.lineBounds
  let line = e.text[start ..< stop]
  result = line[0 ..< line.len - line.strip(trailing = false).len]
  if line.strip.endsWith(":") or line.strip.endsWith("="):
    result.add "  "

proc showCandidates(e: Editor, items: seq[string]) =
  e.moveBelow()
  var longest = 0
  for item in items:
    longest = max(longest, item.runeLen)
  let columns = max(1, width() div (longest + 2))
  var line = ""
  for i, item in items:
    line.add item.alignLeft(longest + 2)
    if (i + 1) mod columns == 0 or i == items.high:
      stdout.writeLine line.strip(leading = false)
      line = ""
  stdout.flushFile

proc completeHere(e: Editor) =
  if e.complete == nil:
    return
  let (start, _) = e.lineBounds
  let before = e.text[start ..< e.cursor]
  let candidates = e.complete(before)
  if candidates.len == 0:
    stdout.write "\a"
    return
  var common = candidates[0]
  for c in candidates:
    var n = 0
    while n < common.len and n < c.len and common[n] == c[n]:
      inc n
    common.setLen(n)
  if common.len > before.len:
    e.text = e.text[0 ..< start] & common & e.text[e.cursor .. ^1]
    e.cursor = start + common.len
  elif candidates.len > 1:
    var tails: seq[string] = @[]
    for c in candidates:
      tails.add c[c.rfind(' ', last = before.len - 1) + 1 .. ^1]
    e.showCandidates(tails)

proc searchHistory(e: Editor) =
  ## Ctrl-R: incremental search, newest match first.
  var query = ""
  var upto = e.history.high
  while true:
    var match = -1
    for i in countdown(upto, 0):
      if query in e.history[i]:
        match = i
        break
    let shown =
      if match >= 0:
        e.history[match].replace("\n", " ")
      else:
        ""
    e.render("(search)`" & query & "': ", shown, shown.len)
    let key = readKey()
    case key.name
    of "char":
      query.add key.text
    of "backspace":
      if query.len > 0:
        query.setLen(e.prevRune(query.len))
      upto = e.history.high
    of "ctrl-r":
      if match > 0:
        upto = match - 1
    of "enter", "esc", "ctrl-g", "ctrl-c", "left", "right", "home", "end":
      if match >= 0 and key.name notin ["esc", "ctrl-g", "ctrl-c"]:
        e.text = e.history[match]
        e.cursor = e.text.len
      return
    else:
      discard

proc handle(e: Editor, key: Key): bool =
  ## Applies a key. Returns true when the input is accepted.
  case key.name
  of "char":
    e.insert key.text
  of "paste":
    e.insert key.text
  of "enter":
    if e.needsMore != nil and e.needsMore(e.text):
      e.insert "\n" & e.autoIndent()
    else:
      return true
  of "ctrl-j", "alt-enter":
    e.insert "\n" & e.autoIndent()
  of "tab":
    e.completeHere()
  of "backspace":
    if e.cursor > 0:
      let p = e.prevRune(e.cursor)
      e.text.delete(p ..< e.cursor)
      e.cursor = p
  of "delete", "ctrl-d":
    if e.cursor < e.text.len:
      e.text.delete(e.cursor ..< e.nextRune(e.cursor))
  of "left", "ctrl-b":
    e.cursor = e.prevRune(e.cursor)
  of "right", "ctrl-f":
    e.cursor = e.nextRune(e.cursor)
  of "home", "ctrl-a":
    e.cursor = e.lineBounds.start
  of "end", "ctrl-e":
    e.cursor = e.lineBounds.stop
  of "alt-b", "alt-left", "ctrl-left":
    e.cursor = e.wordStart
  of "alt-f", "alt-right", "ctrl-right":
    e.cursor = e.wordEnd
  of "up", "ctrl-p":
    if key.name == "ctrl-p" or not e.moveLine(-1):
      e.useHistory(e.historyIndex - 1)
  of "down", "ctrl-n":
    if key.name == "ctrl-n" or not e.moveLine(1):
      e.useHistory(e.historyIndex + 1)
  of "ctrl-k":
    e.deleteRange(e.cursor, e.lineBounds.stop)
  of "ctrl-u":
    e.deleteRange(e.lineBounds.start, e.cursor)
  of "ctrl-w", "alt-backspace":
    e.deleteRange(e.wordStart, e.cursor)
  of "alt-d":
    e.deleteRange(e.cursor, e.wordEnd)
  of "ctrl-y":
    e.insert e.killed
  of "ctrl-l":
    stdout.write "\e[H\e[2J"
    e.cursorRow = 0
  of "ctrl-r":
    e.searchHistory()
  of "ctrl-c":
    e.moveBelow()
    e.text = ""
    e.cursor = 0
    e.historyIndex = e.history.len
  else:
    discard
  false

proc readInput*(e: Editor, prompt, continuation: string, text: var string): bool =
  ## Reads one input, which may span lines. Returns false at end of input.
  e.text = ""
  e.cursor = 0
  e.prompt = prompt
  e.continuation = continuation
  e.cursorRow = 0
  e.historyIndex = e.history.len
  active = e
  enableRaw()
  defer:
    active = nil
    disableRaw()
  e.render()
  while true:
    let key = readKey()
    if key.name == "eof" or (key.name == "ctrl-d" and e.text.len == 0):
      e.moveBelow()
      return false
    if key.name notin ["char", "paste"] and e.userKey != nil and e.userKey(key.name):
      e.render()
      continue
    if e.handle(key):
      e.moveBelow()
      text = e.text.strip(leading = false) # drop the blank line that ended a block
      return true
    e.render()

# For key bindings written in Nim

proc text*(e: Editor): string =
  e.text

proc cursor*(e: Editor): int =
  e.cursor

proc setText*(e: Editor, text: string, cursor: int) =
  e.text = text
  e.cursor = max(0, min(cursor, text.len))

proc insertText*(e: Editor, s: string) =
  e.insert s
