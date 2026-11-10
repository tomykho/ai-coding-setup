# idle-shutdown

Power the machine off when nothing AI-ish is happening, and never while something is.

## Rule

```
activity = newest( allowlisted OmniRoute request, pig transcript write, boot )
session  = pig process running  |  open SSH connection

power off ⇔ activity older than (session ? OPEN_MIN : IDLE_MIN)  and no blocker
```

| Situation | Tier | Result |
|---|---|---|
| No `pig`, no SSH | `IDLE_MIN` = 60 min | off |
| `pig` open but AFK (forgot to close it) | `OPEN_MIN` = 120 min | off; resume with `pig --continue` |
| SSH shell left open | `OPEN_MIN` = 120 min | off — buys time, does not reset the clock |
| Any allowlisted request from any machine, completed | — | clock resets |
| `pig` mid-tool, `dpkg`/`apt` running, or hold file present | — | blocked |

## Signals

| Signal | Read from | Why |
|---|---|---|
| Activity | newest `call_logs` row on an allowlisted path in `~/.omniroute/storage.sqlite` | every `/v1/*` request counts, from any machine. Rows are written at completion |
| Activity | newest mtime of `~/.pig/agent/sessions/**/*.jsonl` and `~/.pi/agent/sessions/**/*.jsonl` (sandboxed PiG writes the latter) | one line per message/tool call; an AFK-but-open TUI writes nothing |
| Activity | `/proc/stat` `btime` | a freshly booted box is never idle |
| Session | `pgrep -x pig` | the agent is still open |
| Session | `ss` established on `SSH_PORT`, non-loopback peer | a shell you forgot to close |

The DB is opened `mode=ro`, never `immutable=1`: the live WAL holds the newest rows.
Loopback peers are excluded, so an `ssh localhost` is not a session.

`call_logs` also holds OmniRoute's own traffic: it re-tests every provider connection
every hour (`POST /api/providers/test`, 3 rows) and syncs model lists. Those rows are not
anyone using the machine, but they land in the same table and would reset the clock
forever — the box would never reach the threshold.

So the table is read **default-deny**: only these prefixes count.

| Knob | Default |
|---|---|
| `OMNI_ALLOW_PATHS` | `/v1/messages,/v1/responses,/v1/chat/completions` — comma-separated literal prefixes (`/v1/` widens to the whole subtree; empty = count every row) |
| `OMNI_INTERNAL_PATHS` | `/api/` — known housekeeping, skipped silently |

The allowlist is deliberately not a blocklist: housekeeping endpoints only ever get
*added* over time, and an allowlist ignores them by construction instead of needing to
learn each one. The cost is the reverse risk — a real endpoint that is not on the list is
invisible. To keep that discoverable, a skipped row that is neither housekeeping nor
`unknown`/absent-path is logged for the last `IDLE_MIN` minutes:

```
idle-check: ignoring call_logs path /v1/embeddings at 2026-11-09T21:04:11.220Z;
            add it to OMNI_ALLOW_PATHS if that is real traffic
```

If the query itself breaks (schema drift), the script logs a warning and falls back to
the unfiltered newest row: an unreadable signal must never look like silence, or the box
would power off while requests are flowing. `omni=?` in a verdict means no allowlisted
request was found at all.

## Known gaps

`call_logs` only gets a row when a request finishes, so a *remote* request that starts in
the last minute before the deadline can still be cut off. Requests from `pig` on this box
are protected, because the tool call is a child process of `pig` and blocks the shutdown.
A cut-off remote request costs one retry; transcripts are on disk and `pig --continue`
resumes.

A request on a path outside `OMNI_ALLOW_PATHS` (`/v1/embeddings`, a future `/v2/…`, a
client posting somewhere unexpected) is likewise invisible: the box reads it as silence and
can power off mid-request. Such rows are logged for `IDLE_MIN` minutes, so after wiring up
a new endpoint check `idle-ctl log`. Widen the list with `OMNI_ALLOW_PATHS=/v1/` to cover a
whole subtree.

An SSH session buys the 2 h tier but does not reset the activity clock — shell work is not
observable here. If you SSH in after hours of quiet and work for 15 minutes, the box can
power off when you finish. Use `idle-ctl hold` for that case. Set `SSH_PORT=` in the conf
to make SSH invisible again.

Connections to the OmniRoute port are deliberately **not** watched. A GUI client on
another machine only counts through its requests (`call_logs`), so a client that is
attached but silent gets the 1 h tier, not 2 h. Over an SSH tunnel it still counts as
`ssh(1)`.

## Install

```bash
./install.sh idle            # prints what would change
./install.sh idle --apply    # installs live: DRY_RUN=0, 60/120 min
./install.sh idle --apply 10 20   # live, 10 min idle / 20 min with a session open
```

Writes `/etc/idle-check.conf` (with `IDLE_MIN`/`OPEN_MIN` set from the arguments),
`/usr/local/bin/idle-check.sh`, `/usr/local/bin/idle-ctl`,
and `idle-check.{service,timer}` (every 5 min, first run 10 min after boot). Not part of
`./install.sh all`, because it changes machine behaviour.

To rehearse before arming it:

```bash
sudo sed -i 's/^DRY_RUN=0/DRY_RUN=1/' /etc/idle-check.conf   # log only
sudo journalctl -u idle-check -f
idle-ctl status                     # one verdict, exit 10 if it would power off
sudo sed -i 's/^DRY_RUN=1/DRY_RUN=0/' /etc/idle-check.conf   # live again
```

One auditable line per cycle:

```
verdict=keep idle=37m tier=120m session=pi(2054),ssh(2) last=omni omni=0m pi=37m boot=49m blockers=pi-busy
```

## Controls

| Command | Effect |
|---|---|
| `idle-ctl hold` | stop powering off (maintenance, long build): touches `/run/idle-shutdown-hold` |
| `idle-ctl release` | allow it again |
| `idle-ctl test [idle] [open] [minutes]` | trial run with short tiers (default 5/10, revert after 120 min) |
| `idle-ctl normal` | end a trial run now |
| `idle-ctl now` | run a real check now (still respects `DRY_RUN`) |
| `idle-ctl log` | last verdicts from the journal |

`/run` is tmpfs, so a hold does not survive a reboot — deliberate.

## Try it out

A 60 min tier is a long time to wait, so trials use a shorter one:

```bash
sudo idle-ctl test                  # 5m idle, 10m with a session, warns 15s
sudo idle-ctl test 2 3 30           # 2m/3m tiers, revert after 30 min
journalctl -u idle-check.service -f # watch the verdicts
sudo idle-ctl now                   # skip the wait: real check, powers off after the warning
sudo idle-ctl normal                # end the trial early
```

Trial values live in `/run/idle-shutdown-test`, not in `/etc/idle-check.conf`, for three
reasons: a reboot clears it, it expires on its own (`UNTIL=`), and a short tier can never
be forgotten and left armed. Verdicts carry `mode=test` while a trial runs, and the file
is only sourced if it is owned by root (or by the user, for an unprivileged
`idle-ctl status`) — the service runs as root, so a file another user can rewrite is
refused.

The timer still fires every 5 min, so a `test 5 10` trial acts on the next tick: up to
~5 min later than the tier suggests. Use `idle-ctl now` for a deterministic try.

## Test

```bash
./test_idle_check.sh
```

Fake DB, fake transcripts, fake `pig` process, a real socket for the client case,
`DRY_RUN=1`, no root, no systemd, no poweroff.

## Wake it up again

Wake-on-LAN works on this NIC (`enp195s0`). From outside the LAN, the OpenWrt router can
send the magic packet (`wakeonlan`) once you can route in over WireGuard or Tailscale. A
smart plug with "restore on AC power loss" enabled in the BIOS is the fallback. Suspend is
not an option here: the box only offers `s2idle`, no S3.

## Uninstall

```bash
sudo systemctl disable --now idle-check.timer
sudo rm -f /etc/systemd/system/idle-check.{service,timer} \
           /usr/local/bin/idle-{check.sh,ctl} /etc/idle-check.conf
sudo systemctl daemon-reload
```
