# FINDING shape

A track sends this for anything it noticed outside its task, with its next status message. It
does not fix it, file it or ignore it. A file it needs outside its scope is a finding too.

```
FINDING: <one line: what, where (file:line), how observed (measured / reasoned / read)>
  evidence: <the command or test that showed it, or "reasoned, not measured">
  scope: outside mine (<owner track, or nobody>) | mine but outside this task
  severity guess: live exposure | latent | cosmetic
  suggested next step: widen scope | own track | backlog line | investigate first | drop
```

The five next steps, which are also the five outcomes the coordinator records:

| Next step | Means | Recorded outcome |
|---|---|---|
| widen scope | the named track (the reporter or the owner) fixes it in its own PR; that ledger row's scope grows | `widen scope: <track>, <globs>`, plus an owed check |
| own track | it becomes its own track or PR, now or later | `own track: <who>`, plus an owed check |
| backlog line | written down where the repo keeps its backlog | `backlog line: <where>` |
| investigate first | someone reproduces it before anyone believes it | `investigate first: <who>`, plus an owed check |
| drop | not worth acting on | `drop: because ...` |

**Live exposure** (a security hole or data leak that is reachable now) goes to the coordinator in
a private message only, never into a PR body, a commit message, a report or any other file that is
committed or posted, and never into a WIP line. A track sends it at once, not with its next
status message. In a public repository a PR body is readable by anyone the moment it is posted. If
one is to be fixed, the user decides how and when anything about it is pushed or posted.

Example:

```
FINDING: retry loop in src/sync/client.ts:88 never resets its backoff after a success (read)
  evidence: reasoned, not measured
  scope: outside mine (track T3, owns src/sync/**)
  severity guess: latent
  suggested next step: investigate first
```

The coordinator logs it as `F<n>` with outcome PENDING, puts it to the user with a recommendation,
records the outcome as its own `F<n> outcome: ...` line, and tells the track what was decided.

A **blocker** for the track's own task is not a finding: the track tells the user in its own
window and the coordinator, at once, and stops until answered.
