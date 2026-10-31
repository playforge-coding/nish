## Jobs: process groups, who owns the terminal, and `jobs`, `fg` and `bg`.
##
## Each pipeline is a job. At an interactive prompt every job gets its own
## process group, the foreground job owns the terminal while it runs, and
## Ctrl-Z stops it and returns to the prompt. Without a terminal (scripts,
## piped input) jobs share the shell's group and only `&` and `fg` matter,
## as in other shells.

import std/[posix, strutils]

type
  JobState* = enum
    jsRunning
    jsStopped
    jsDone

  Job* = ref object
    id*: int
    pgid*: Pid
    left: seq[Pid] ## processes that have not exited yet
    lastPid: Pid ## the job's status is this process's
    command*: string
    state*: JobState
    status*: int
    stateReported: JobState ## the last state the user was told about

var
  jobControl* = false ## whether jobs get their own groups and the terminal
  shellPgid: Pid
  jobs: seq[Job] = @[]
  nextId = 1

const ttyFd: cint = 0

# Signals the shell must survive. Children reset them before `exec`.
let
  jobSignals = [SIGINT, SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU]
  terminalSignals = [SIGTSTP, SIGTTIN, SIGTTOU]

proc ignore(sig: cint) {.noconv.} =
  discard

proc enableJobControl*() =
  ## Call once when the shell reads from a terminal. Without one, Ctrl-C
  ## must keep stopping the shell itself, as it does any script.
  if isatty(ttyFd) == 0:
    return
  # A handler, unlike `SIG_IGN`, resets to the default when a child runs
  # `exec`, so programs the shell starts still die from Ctrl-C.
  signal(SIGINT, ignore)
  signal(SIGQUIT, ignore)
  # These must really be ignored: `tcsetpgrp` from outside the foreground
  # group fails with EINTR when SIGTTOU merely has a handler.
  for sig in terminalSignals:
    signal(sig, SIG_IGN)
  jobControl = true
  if getpgrp() != getpid():
    discard setpgid(0, 0)
  shellPgid = getpgrp()
  discard tcsetpgrp(ttyFd, shellPgid)

proc childJobSetup*(pgid: Pid, foreground, stoppable: bool) =
  ## Between `fork` and `exec` in the child. Only async-signal-safe calls.
  ## A job that isn't `stoppable` ignores Ctrl-Z; an ignored signal stays
  ## ignored across `exec`.
  if jobControl:
    let group =
      if pgid == 0:
        getpid()
      else:
        pgid
    discard setpgid(0, group)
    if foreground:
      discard tcsetpgrp(ttyFd, group)
    for sig in jobSignals:
      signal(sig, SIG_DFL)
  if not stoppable:
    signal(SIGTSTP, SIG_IGN)

proc parentJobSetup*(pid: Pid, pgid: var Pid, foreground: bool) =
  ## After `fork` in the parent. Both sides set the group and the terminal,
  ## so it holds whichever of them runs first.
  if not jobControl:
    return
  if pgid == 0:
    pgid = pid
  discard setpgid(pid, pgid)
  if foreground:
    discard tcsetpgrp(ttyFd, pgid)

proc decode(status: cint): int =
  if WIFEXITED(status):
    WEXITSTATUS(status)
  elif WIFSIGNALED(status):
    128 + WTERMSIG(status)
  elif WIFSTOPPED(status):
    128 + WSTOPSIG(status)
  else:
    1

proc addJob*(pgid: Pid, pids: seq[Pid], command: string): Job =
  result = Job(
    id: nextId,
    pgid: pgid,
    left: pids,
    lastPid: pids[^1],
    command: command,
    state: jsRunning,
    stateReported: jsRunning,
  )
  inc nextId
  jobs.add result

proc forget(job: Job) =
  let i = jobs.find(job)
  if i >= 0:
    jobs.delete(i)
  if jobs.len == 0:
    nextId = 1

proc update(job: Job, pid: Pid, status: cint) =
  if WIFSTOPPED(status):
    job.state = jsStopped
    job.status = decode(status)
    return
  let i = job.left.find(pid)
  if i >= 0:
    job.left.delete(i)
  if pid == job.lastPid:
    job.status = decode(status)
  if job.left.len == 0:
    job.state = jsDone

proc describe(job: Job): string =
  let state =
    case job.state
    of jsRunning:
      "Running"
    of jsStopped:
      "Stopped"
    of jsDone:
      if job.status == 0:
        "Done"
      else:
        "Exit " & $job.status
  "[" & $job.id & "]  " & state.alignLeft(10) & job.command

proc report(job: Job) =
  stderr.writeLine describe(job)
  job.stateReported = job.state

proc takeTerminalBack*() =
  if jobControl:
    discard tcsetpgrp(ttyFd, shellPgid)

proc waitForeground*(job: Job): int =
  ## Waits until the job finishes or stops, then takes the terminal back.
  ## Returns its exit status, or 128 plus the signal for a stopped job.
  job.state = jsRunning
  while job.state == jsRunning:
    var status: cint = 0
    let pid = waitpid(job.left[0], status, WUNTRACED)
    if pid > 0:
      job.update(pid, status)
    elif errno != EINTR:
      job.left.delete(0)
      if job.left.len == 0:
        job.state = jsDone
        job.status = 1
  takeTerminalBack()
  result = job.status
  if job.state == jsStopped:
    stderr.writeLine ""
    job.report()
  else:
    job.forget()

proc startBackground*(job: Job) =
  ## Announces the job with its first process, which leads its group when
  ## there is job control. Without it `pgid` is 0.
  stderr.writeLine "[", job.id, "] ", job.left[0]

proc notify*() =
  ## Reports background jobs that finished or stopped since the last prompt.
  for job in jobs:
    var i = 0
    while i < job.left.len and job.state != jsStopped:
      var status: cint = 0
      let pid = waitpid(job.left[i], status, WNOHANG or WUNTRACED)
      if pid > 0:
        job.update(pid, status)
      else:
        inc i
  for job in jobs:
    if job.state != job.stateReported:
      job.report()
  for i in countdown(jobs.high, 0):
    if jobs[i].state == jsDone:
      jobs[i].forget()

proc find(id: int): Job =
  ## Job `id`, or with 0 the most recent one, stopped jobs first.
  if id == 0:
    for job in jobs:
      if job.state == jsStopped:
        result = job
    if result == nil and jobs.len > 0:
      result = jobs[^1]
  else:
    for job in jobs:
      if job.id == id:
        result = job
  if result == nil:
    stderr.writeLine "nish: ",
      (if id == 0: "no current job" else: "no such job: " & $id)

proc continueJob(job: Job) =
  if job.state == jsStopped:
    if jobControl:
      discard kill(-job.pgid, SIGCONT)
    else:
      # No group of its own: `pgid` is 0, and signalling group 0 would wake
      # every stopped process in the shell's group.
      for pid in job.left:
        discard kill(pid, SIGCONT)
  job.state = jsRunning
  job.stateReported = jsRunning

proc foreground*(id: int): int =
  ## `fg`: brings a job to the foreground and waits for it.
  let job = find(id)
  if job == nil:
    return 1
  stderr.writeLine job.command
  if jobControl:
    discard tcsetpgrp(ttyFd, job.pgid)
  job.continueJob()
  waitForeground(job)

proc background*(id: int) =
  ## `bg`: lets a stopped job go on in the background.
  let job = find(id)
  if job == nil:
    return
  job.continueJob()
  stderr.writeLine "[", job.id, "] ", job.command, " &"

proc listJobs*() =
  notify()
  for job in jobs:
    stdout.writeLine describe(job)
