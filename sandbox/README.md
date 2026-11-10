# Sandboxing pi for remote sessions

Goal: sessions started from a remote client (Paseo, PiChamber, plain SSH) may only
touch `/home/tomykho/Projects`. Nothing else on the machine.

## Why a separate `piagent` user is the wrong lever here

A new UID does narrow permissions, but in *this* setup it breaks the two things that
depend on the existing user, and it still needs ACL work to reach `Projects`
(`/home/tomykho` is `0750`):

| Breaks | How |
| --- | --- |
| `idle-shutdown` | `/etc/idle-check.conf` pins `PI_USER=tomykho` / `PI_HOME=/home/tomykho`, and `pi_last_write()` scans exactly one `PI_SESSIONS_DIR`. A `piagent` session writes transcripts to `/home/piagent/.pi/agent/sessions`, so the clock never resets. `pi_pids()` falls back to `pgrep -x pi` across *all* users, so the tier becomes `OPEN_MIN` (120 min) — a long remote session gets the machine powered off underneath it. |
| OmniRoute | runs as `tomykho` via `systemd --user`, with keys in `~/.omniroute/.env` and `storage.sqlite` in `~/.omniroute/`. A second user would need group access to the DB/keys, and the router's own config is per-user. |
| pi itself | the managed install (`~/.pi/agent/install`, private node in `~/.local/share/pi-node`) and `models.json`/`auth.json` are per-user; a new user needs a second copy, which then drifts on every `pi update`. |

Worse: the UID boundary does not express "only Projects". You would still need
`setfacl`/group on `Projects`, and `piagent` would still read `/etc`, `/var`, `/tmp`
and every world-readable file.

## What this does instead

Same UID (`tomykho`), different *namespace*. `pi-sandbox.sh` starts pi under
[bubblewrap](https://github.com/containers/bubblewrap) with:

- `/home` **not mounted at all** — only `$PI_SANDBOX_ROOT` (`~/Projects`) is bound rw
- **only this workspace's** session dir (`…/sessions/--<encoded cwd>--`) rw,
  because the transcript writes are the idle-shutdown signal. The rest of the
  sessions tree stays unmounted, so a session cannot read the prompts of sessions
  run from `~`, `/tmp` or any other tree. `install/`, `bin/`, `settings.json` and
  `models.json` are read-only, so neither `pi update` nor the launcher nor the
  extension list can be tampered with. `auth.json` and `extensions/` are **not
  mounted at all** — see "Write-side pivot" below.
- everything else read-only and minimal: `/usr`, `/bin`, `/lib`, `/etc`, DNS resolver, pi's node
- `/tmp` private tmpfs, PID/IPC/UTS namespaces, clean environment (no `GH_TOKEN`,
  `SSH_AUTH_SOCK`, `ANTHROPIC_API_KEY`, ...), no `~/.ssh`, no `~/.omniroute`
- network **shared** — pi must reach OmniRoute on `127.0.0.1:20128`, and that same
  traffic is what `omni_last_request()` reads to reset the idle clock

Because the UID is unchanged, `idle-check.sh` and OmniRoute need no changes at all:
`pgrep -u tomykho -x pi` still finds the process, `pi_busy()` still sees its children
(the sandbox is a child of the launcher, visible on the host), transcripts still land
in the same directory, and requests still produce `call_logs` rows.

## Install

```bash
sudo apt install bubblewrap          # one package; Ubuntu's apparmor profile
                                     # (bwrap-userns-restrict) already allows it
sudo install -m 0755 sandbox/pi-sandbox.sh /usr/local/bin/pi-sandbox
```

Point the remote client at `pi-sandbox` instead of `pi` (same arguments). Keep an
unsandboxed `pi` on the host for setup work.

`./install.sh sandbox --apply` does the two commands above, plus `gh-mint.sh
install` (the token broker, user-owned, inert until an App is configured).

## Which `pi` runs inside

Pi-Bolt's AOT binary (`~/.pi-bolt/*/pi`) when it is installed, otherwise the
upstream launcher at `~/.pi/agent/bin/pi`. Because `$HOME` is a private tmpfs in
the sandbox, Pi-Bolt's whole install directory is bound read-only at
`/opt/pi-runtime`, so the binary finds its `assets/`, `theme/`, `skills/` and
`photon_rs_bg.wasm`. Override the choice with `PI_SANDBOX_PI_BIN`:

```bash
PI_SANDBOX_PI_BIN=/path/to/pi  pi-sandbox      # an explicit binary
PI_SANDBOX_PI_BIN=pi           pi-sandbox      # looked up on PATH → upstream
```

`--check` prints the resolved binary and its version.

## Paseo

Paseo is the one remote client that **spawns the `pi` binary** (JSONL-RPC,
`packages/server/.../providers/pi/cli-runtime.ts`), which is why it can be
sandboxed at all. But the boundary does **not** go around `pi` — it goes around
the **daemon**.

The daemon is long-lived and does host-side work of its own: terminal panes
(real host shells), `clone`, worktree creation, and reading files to render
diffs. Wrapping only the agent leaves all of that with the whole home directory,
which is exactly how `~/Todo` stays readable even though the agent's own `bash`
cannot see it. `paseo-sandbox.sh` wraps the daemon instead, with `$HOME`
replaced by the sandbox root, so it sees only `Projects` (which now contains
Paseo's own state), Pi-Bolt's install dir, the node install dir, `.gitconfig`,
`~/.pi/agent/{models.json,install,bin,…}` and the session dirs of workspaces
inside `Projects`. Every child it creates inherits that view.

### The two sandboxes cannot nest

Tempting to keep both (daemon wrapped *and* pi wrapped). It does not work here:

```
bwrap: No permissions to create a new namespace, likely because the kernel
       does not allow non-privileged user namespaces
```

Ubuntu 24.04 restricts unprivileged user-namespace creation through AppArmor, so
an inner bwrap dies inside an outer bwrap. One layer only — and the daemon layer
is strictly broader, so it belongs there. Paseo therefore spawns a plain `pi`:

```ini
Environment=PI_COMMAND=%h/.pi-bolt/pi-bolt-linux-x64/pi
```

Consequence worth knowing: the agent shares the daemon's namespace, so it can
read Paseo's state (*now* `~/Projects/.paseo`, see below), including the local
daemon credential. That grants only *confined* powers — terminal panes, clones
and worktrees still land inside `~/Projects`, because the daemon has nowhere
else to write. Hiding `.paseo` from the agent in particular needs a second
namespace, i.e. the nesting that is blocked here.

### Two settings Paseo still needs

**`TMPDIR` must be inside the writable tree.** Paseo hands pi an extension and
an MCP config it writes itself:

```js
mkdtempSync(join(tmpdir(), "paseo-pi-extension-"))   // and "paseo-pi-mcp-"
```

`TMPDIR` points at `~/Projects/.paseo-tmp`, so those files exist in the
namespace. (When the sandbox sat around pi instead of the daemon this was fatal:
`Failed to load extension … Extension path does not exist`.)

**Worktrees are already in the tree.** With `PASEO_HOME` moved to
`~/Projects/.paseo`, the default `worktrees/<projectHash>/<slug>` lands inside
`~/Projects` and its transcripts are picked up by the session rule below. Nothing
to configure; keep `{ "worktrees": { "root": "…" } }` only if you want a
shorter path than `~/Projects/.paseo/worktrees`.

### The unit

```ini
# ~/.config/systemd/user/paseo.service
[Service]
Type=simple
Environment=PATH=%h/.local/share/fnm/node-versions/v26.13.0/installation/bin:/usr/local/bin:/usr/bin:/bin
Environment=PI_COMMAND=%h/.pi-bolt/pi-bolt-linux-x64/pi
Environment=TMPDIR=%h/Projects/.paseo-tmp
# Must match what paseo-sandbox.sh exports, or the host CLI looks for the daemon
# in ~/.paseo and reports it as down.
Environment=PASEO_HOME=%h/Projects/.paseo
ExecStart=%h/Projects/ai-coding-setup/sandbox/paseo-sandbox.sh \
  %h/.local/share/fnm/node-versions/v26.13.0/installation/bin/paseo daemon run
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
```

**`PASEO_HOME` applies to you too.** The daemon gets it from the script's
`export`, but your interactive `paseo status` / `paseo run` reads
`~/.paseo` unless the same variable (or `--home`) is set. Put it in your shell
profile, or every host-side CLI call will report no daemon.

`PI_COMMAND`, `TMPDIR` and `PASEO_HOME` must be in the environment of the process that starts
the **supervisor**: `paseo restart` "restarts the selected daemon worker,
retaining its supervisor launch", and neither `paseo start` nor
`paseo daemon start` accepts an env flag.

Do not try `TemporaryFileSystem=` / `BindPaths=` here: a *user* unit cannot set
up a mount namespace and dies with `226/NAMESPACE` (operation not supported).
That is why the wrapping happens in the script.

### What is still writable outside `~/Projects`

Nothing. `~/Projects` is the only writable host tree; Paseo's state moved inside
it (`PASEO_SANDBOX_STATE`, default `~/Projects/.paseo`) and the script only adds
a separate bind if you override that to a path outside the tree.

Migration from the old layout, once, on the host:

```bash
mv ~/.paseo ~/Projects/.paseo            # projects, schedules, credential
export PASEO_HOME=$HOME/Projects/.paseo  # add to your shell profile
systemctl --user daemon-reload && systemctl --user restart paseo
```

Clients paired with the old daemon need re-pairing, because
`local-credential` and `daemon-keypair.json` moved with the directory. Worktrees
recorded at `~/.paseo/worktrees/…` are recreated on demand at the new location
(or stay put if you already set `worktrees.root` to
`~/Projects/.paseo-worktrees`). Do not also set `PASEO_HOST` in the unit: paseo
refuses to start when both it and `PASEO_HOME` are present.

`$HOME` is mounted as a tmpfs and then `--remount-ro`, so any write elsewhere —
`mkdir ~/test2` from the app's new-project flow, or from an agent — fails with
`EROFS` instead of silently landing in a throwaway overlay that is invisible
from the host and vanishes on restart. That silent write is the trap: the GUI
reports success, the directory exists inside the namespace, and `ls ~` on the
host shows nothing at all.

Two locations stay writable but **ephemeral**: Paseo's caches (`.cache`,
`.config`, `.claude`, `.codex`, `.bun`) and pi's own agent dir (`~/.pi/agent`,
where pi writes `trust.json` — without it pi dies with
`EROFS: read-only file system, mkdir '…/trust.json.lock'`). Those are the
directories Paseo itself populates at start (hooks in `.claude`/`.codex`, its
opencode plugin in `.config`), so they must exist and be writable, and because
they are tmpfs the host copies are never read and nothing written there
survives. Model config is bound read-only inside `~/.pi/agent`; sessions are
handled next.

### Transcripts: only in-tree workspaces are mounted

`~/.pi/agent/sessions` used to be bound whole and read-write. That directory is
this machine's *entire* agent history — transcripts from `cwd=/home/tomykho`,
`/tmp`, `/tmp/bench` and every other tree — so any session could read every
prompt ever typed here, including anything pasted into them. It was also
writable, which made it an evidence-loss and idle-clock primitive.

The script now binds only session dirs belonging to workspaces inside
`~/Projects`. pi names them after the encoded cwd
(`/home/tomykho/Projects/foo` → `--home-tomykho-Projects-foo--`), so a prefix
match covers any nesting depth, including new worktrees. Everything else stays
unmounted; `~/.pi/agent/sessions` in the namespace is an empty tmpfs dir.

Two consequences:

- A workspace created *after* the daemon started has no session dir to bind, so
  its transcript lands in the tmpfs and is lost. Restart the unit, or declare
  the path ahead of time:

  ```bash
  PI_SANDBOX_SESSIONS_RW=$HOME/Projects/newthing:… paseo-sandbox.sh …
  ```

- `idle-shutdown` is unaffected: `pi_last_write()` reads the host directory
  directly, so transcripts still reset the clock exactly as before.

Verified: `paseo run --provider pi` starts the daemon in its own mount namespace;
the agent's `/proc/<pid>/root/home/tomykho` contains only
`Projects .pi .local .pi-bolt .config .claude .codex .bun`; `Todo`,
`Documents`, `.ssh` and `.omniroute` are absent; the agent reaches
`omniroute/…` and goes idle with tokens billed. The `pi` it runs is
`/home/tomykho/.pi-bolt/pi-bolt-linux-x64/pi`, cwd = the workspace.

PiChamber cannot be used this way at any setting: it imports
`@earendil-works/pi-coding-agent` as a library and runs the session daemon
in-process, so there is no `pi` process to wrap — and no alias or symlink can
change that, because Pi-Bolt ships no importable `dist/`.

## Verify

```bash
pi-sandbox --check      # prints what is visible / writable / reachable
pi-sandbox --shell      # a bash inside the same boundary, for poking around
```

Actual output on this machine (bubblewrap 0.11.1, Ubuntu 24.04):

```
--- visible in /home:
tomykho
--- sibling of Projects reachable?
  hidden   /home/tomykho/.ssh
  hidden   /home/tomykho/.omniroute
  hidden   /home/tomykho/Documents
  hidden   /home/tomykho/.pi/agent/auth.json
  hidden   /home/tomykho/.pi/agent/extensions
  readable /home/tomykho/.pi/agent/settings.json (ro)
--- writable?
  yes: /home/tomykho/Projects (host)
  /home/tomykho is a private tmpfs here: writes vanish at exit, host untouched
--- node: .../fnm/node-versions/v26.13.0/installation/bin/node (v26.13.0)
--- OmniRoute reachable: yes (tcp 20128)
--- processes visible: 5
```

`~/Projects` is the real host directory; `/home/tomykho` itself is an empty tmpfs
created for the two bind mounts, so anything written there is discarded on exit.

## GitHub access

The sandbox gets GitHub credentials from one of two sources, chosen by
`PI_SANDBOX_GH`:

| Mode | What enters the namespace | Blast radius if the agent is hijacked |
| --- | --- | --- |
| `app` (default once an owner exists; `broker` is an alias) | one unix socket; the host answers per call | 60 minutes and the installation's repos, where an App exists; the PAT's own repo list and expiry where one cannot |
| `legacy` | `~/.config/gh`, writable | the account's OAuth `repo` scope, plus a ~6-month refresh token |

`app` takes over automatically as soon as one owner is configured under
`~/.config/gh-mint/`; `PI_SANDBOX_GH=legacy` forces the old behaviour back.
Neither mode mounts `~/.ssh`, and in `app` mode the key material never enters the
namespace at all.

That is the design, not the current state: with no owner configured the sandbox
stays in `legacy` mode. What is built, what is deliberately deferred (the App for
this account, the collaborator-only owner, public vs private visibility) and the
exact steps to unpark each are in [`gh-mint/TODO.md`](gh-mint/TODO.md).

### App mode

`gh-mint.service` runs on the host under your UID, holds the App private keys, and
answers exactly one question over `/run/user/<uid>/gh-mint/gh-mint.sock`: "token
for owner X". Each answer is a GitHub **installation token** — 60 minutes, one
installation's repositories, one installation's permissions. GitHub hardcodes the
hour and offers no way to ask for more, which is the feature: a leaked sandbox dies
within the hour, having never been able to reach a repo the App was not installed
on.

The socket is the only authority in there, and it never hands out more than the
installation already allows — so it does not matter that the agent can call it
directly with `curl`, which is exactly what defeated the earlier allowlist design.

Both the shim and the helper mint on every invocation, so a long session never
carries a token more than seconds old:

- `gh` on `PATH` is `/opt/gh-mint/bin/gh`, read-only from the host. It mints for
the repo's owner (`git remote get-url origin`), then execs the real `gh` with
`GH_TOKEN`. A repo whose owner has no App fails loudly instead of borrowing
another owner's token.
- git calls `gh-mint-credential`. With
`credential.https://github.com.useHttpPath` git passes `path=<owner>/<repo>.git`,
which is what lets one sandbox serve several owners, one App each.

```bash
GIT_CONFIG_COUNT=3
GIT_CONFIG_KEY_0=credential.https://github.com.helper
GIT_CONFIG_VALUE_0='!gh-mint-credential'
GIT_CONFIG_KEY_1=credential.https://github.com.useHttpPath
GIT_CONFIG_VALUE_1=true
GIT_CONFIG_KEY_2=url.https://github.com/.insteadOf
GIT_CONFIG_VALUE_2=git@github.com:
```

Setup, once per owner. Whose account it is decides which of the two kinds of owner
you write, and `gh-mint.sh owners` shows what the broker currently serves:

- **you own the account or the org** → an App. Install it yourself; no one's
  permission needed.
- **you are only a collaborator** on someone else's personal account → an App is
  impossible, because a private App installs only on its owner's account and you
  are not that owner. Use a **fine-grained PAT** (see below) — the one credential
  you can create without asking anyone.

A *public* App lifts the first constraint: it can be installed on any account,
including orgs you administer, so one App and one key can serve many owners. The
bill is that anyone may install it, and the key holder can then mint for every one
of those installations — which is why the permission set below stays this narrow
and never includes Administration.

1. `Settings → Developer settings → GitHub Apps → New GitHub App`, named
   `<owner>-sandbox`, Webhook **off**, visibility per the note above ("only on
   this account" or "any account"), **no user permissions**. Repository permissions: **Contents RW**, **Pull requests RW**,
   plus **Workflows RW** if the agent may edit `.github/workflows/` and
   **Issues RW** if it may file issues. Leave **Administration** at No access —
   that one omission is what stops a leaked token from deleting a repo or
disabling a ruleset.
2. Generate a private key, move it out of `~/Downloads`, tighten it:
   `install -m 600 ~/Downloads/<name>.*.pem ~/.config/gh-mint/keys/<owner>.pem`.
   That key mints freely for the installation: it must never enter the sandbox, and
   never be written under `~/Projects` — the one writable tree in there.
3. Install the App on **selected repositories** only, never "All repositories".
4. Record it — `installations` prints the INSTALL_ID:

```bash
~/.config/gh-mint/gh-mint.sh installations
cat >~/.config/gh-mint/apps/<owner>.env <<'EOF'
APP_ID=123456
INSTALL_ID=78901234
KEY_FILE=~/.config/gh-mint/keys/<owner>.pem
EOF
chmod 600 ~/.config/gh-mint/apps/<owner>.env
~/.config/gh-mint/gh-mint.sh check
```

`check` prints the token's expiry and the exact repo list it can reach — if that
list is your whole account, step 3 was "All repositories". `REPOS=` and
`PERMISSIONS=` in the same file narrow further, but must stay a subset of the
App's grant or GitHub answers 422. Then `pi-sandbox --check` shows the mode and
mints one token through the socket.

#### When an App cannot exist: a PAT

For an owner that is someone else's personal account with your access granted as a
collaborator, there is no App to install and no admin to ask — but you do not need
one. A **fine-grained PAT** is the credential *you* can create for repos you can
already write to, and the broker serves it from the same socket, so it never enters
the sandbox at rest:

```bash
install -m 600 /dev/null ~/.config/gh-mint/tokens/<owner>
printf '%s\n' 'github_pat_…' >~/.config/gh-mint/tokens/<owner>
~/.config/gh-mint/gh-mint.sh check --owner <owner>
```

Create it at `Settings → Developer settings → Fine-grained tokens → Generate new`:
resource owner is you, **only select repositories** (the handful that matter), and
**Contents RW + Pull requests RW** with everything else at No access — in
particular no Administration, so it cannot delete a repo or unprotect a branch
even on repos it *can* reach. An expiry is mandatory for fine-grained tokens; pick
the longest you are willing to re-do, and note that a PAT has no hourly re-mint,
so its own repo list and expiry date, not the clock, are the boundary. GitHub
shows the collaborator repositories of other accounts in that list. The broker
reads the file per request, so rotating it is "overwrite the file" — no restart.

### Legacy mode

`~/.config/gh` bound **writable**, so `gh` inside is the host's `gh` — same
account, same scope (`repo`) — refreshing its own token in place, with git
credentials from `gh auth git-credential`. No setup at all, which is why it stays
as the fallback. It is also what an earlier design tried to avoid: an allowlist in
front of `gh` plus a read-only token behind it, both removed, because the allowlist
only constrained `gh` — `curl -X POST …/merge` with the token from the sibling file
bypassed it entirely — and that token had to be rotated by hand or by a timer.
Read-only-ness has to come from the credential, and this box needs push, so the
credential is either the host's own or an App's.

Why the token and not the key, since ssh is normally the safer choice: that is
true of a passphrase-protected key reached through an agent, which is precisely
what a sandbox cannot have. `SSH_AUTH_SOCK` here points at a socket that does not
exist in the namespace — and binding it would be worse, because an agent socket
signs any request, for any host, with no approval step. So the design forces a
passphrase-less key **on disk**, which makes it readable, therefore copyable,
therefore still valid after the session ends. Against that, a gh token is scoped
to GitHub, expires, and dies with `gh auth logout`; the ssh key is account-wide,
has no expiry, and on this host advertises the work identity in its comment
(`tomykho@essedigital`), so it is likely trusted elsewhere too. Verified before
removing the bind: the key had no passphrase (`ssh-keygen -y -P ''` succeeds).

What that means, plainly: in **legacy** mode a prompt-injected session can push to
any branch of any repo the account can reach, force-push, delete branches, and
rewrite your `gh` config — `gh auth logout`, a different account, anything. In
**app** mode it can push only to the installed repos, only for as long as it keeps
minting tokens, i.e. as long as the session runs, and it cannot touch
`~/.config/gh` at all because that path is not mounted.

Either way the boundary holds for the *machine* (`~/Projects` is the only writable
tree; `~/.omniroute`, provider `auth.json`, `~/Documents` and every other session's
transcript stay invisible) and not for GitHub. That is the intended trade — a
session that cannot push cannot do the job — and Paseo's own model says the same
thing: `docs/permissions.md` notes that agents and terminals "can execute code and
mutate the workspace, so separate write permissions would claim an isolation
boundary the daemon cannot enforce". The levers that actually bound the damage are
server-side, not in the sandbox:

- protect `main` with a ruleset — require a PR, block force-push, block deletion —
  so a hijacked session can push a branch but cannot land on the default branch,
  and do not put the App on the ruleset's bypass list;
- keep the credential narrow: an App installation, or a fine-grained PAT. A classic
  PAT's `repo` scope is account-wide over every repo the account can write;
- revoke when a session looks wrong: `gh auth logout` host-side, or *Suspend* the
  App, which kills minting for every sandbox at once, or regenerate its key.

None of that replaces reading the PR. An agent that can push can open a plausible
backdoor; the review step is the control, the token scheme only bounds the window.

Legacy mode's extra exposures, for the record: `hosts.yml` holds an OAuth
**refresh** token good for about six months, so an exfiltrated `~/.config/gh`
outlives the 8-hour access token — and writable means the agent can rewrite it.

Two details this host needs:

- **legacy only**: `~/.config/gh` must stay **writable**, because gh rotates its
  expiring OAuth token by rewriting `hosts.yml`. Mounted read-only, every call
  works until the token's 8-hour expiry, then fails. App mode mounts nothing there.
- `/etc/ssh/ssh_config.d` is masked with an empty tmpfs. Inside a user namespace
  every host root-owned file appears as `nobody:nogroup`, and ssh refuses a config
  file whose ownership it cannot verify — `git fetch` died with `Bad owner or
  permissions on …/20-systemd-ssh-proxy.conf` until that directory was masked.
  `/etc/ssh/ssh_config` itself is still read. Since `GIT_SSH_COMMAND=/bin/false`
  now stops git from invoking ssh at all, the mask is belt-and-braces: an ssh
  attempt fails immediately instead of with an ownership error.

Commits need an identity and this host has none: no `~/.gitconfig`, no repo-local
`user.name`, and `git var GIT_AUTHOR_IDENT` reports "Author identity unknown".
Both sandboxes therefore export `GIT_AUTHOR_NAME`/`EMAIL` and
`GIT_COMMITTER_NAME`/`EMAIL`, defaulting to the account's identity and
overridable from the environment. Without that, every commit inside the sandbox
fails.

```bash
gh pr checkout 123        # local branch from the PR head
npm test
gh pr diff 123 | git apply && npm test   # no git auth at all
```

### Restarting

Mounts are fixed at `exec`, so any change to the mount set — a new bind, a
different `--chdir` — needs `systemctl --user restart paseo.service`. Sessions
already running keep the `pi` process they started, so they see the old
environment until a new session begins.

In **legacy** mode a host-side `gh auth login` or a token refresh needs no restart:
the bind points at the live `~/.config/gh`, so gh's rotated token is already
visible in the running namespace.

In **app** mode nothing needs a restart either, for a different reason: the
broker's *directory* is bound rather than the socket file, so
`systemctl --user restart gh-mint` cannot leave a sandbox pointing at a dead inode.
Adding an App or rotating its key is picked up by the next mint. Only switching
`PI_SANDBOX_GH` (or adding the first App, which changes the mode) needs a
`paseo.service` restart.

End-to-end, and the idle-shutdown interaction it has to preserve:

```
$ pi-sandbox -p "reply with the single word: ok"
ok

$ idle-check.sh --status
verdict=keep idle=0m tier=120m session=pi(2134),ssh(2) last=omni omni=0m pi=0m ...
```

The sandboxed session wrote a normal transcript and a normal `/v1/chat/completions`
row, so both activity signals the idle check reads still fire. Because pi lives in a
PID namespace, the agent also cannot see (or signal) your other sessions or the
OmniRoute process, while `pi_busy()` on the host still sees its running tools.

## Things that intentionally do not work inside

- `pi update` — `~/.pi/agent/install` is read-only; update on the host.

GitHub is no longer in this list: `gh`, `git commit` and `git push` all work
inside, with either credential (see "GitHub access"). In app mode a repo whose
owner has no App configured fails with a mint error rather than a permissions
error, because the shim refuses to guess an owner.
- `git@github.com:` remotes are rewritten to https for you; ssh remotes to *other*
  hosts do not work, since no key is mounted. That is the point — the token
  reaches GitHub and nothing else.
- `git fetch` over ssh against a non-GitHub host fails with an ownership error
  rather than "permission denied" (see the `ssh_config.d` mask above).
- Builds that need a cache outside the tree (`~/.cargo`, `~/.npm`, `~/.cache`).
  Opt in per path when a project really needs it:

  ```bash
  PI_SANDBOX_EXTRA=$HOME/.cargo,$HOME/.npm pi-sandbox
  PI_SANDBOX_EXTRA_RO=$HOME/.rustup pi-sandbox
  ```

  Every extra bind is a hole; prefer leaving them out.

## Limits of this boundary

- The agent can still reach the network (OmniRoute needs it). Exfiltration is not
  prevented, only filesystem access is.
- The tmpfs at `/home/tomykho` and `/tmp` come out of RAM: a runaway write inside the
  sandbox can eat memory. It cannot corrupt anything on disk, but it can make the box
  unhappy until the session ends.
- ~~`~/.pi/agent` is writable as a whole~~ — fixed. Only one session dir under
  `sessions/` is rw (and only the ones for in-tree workspaces are mounted at all);
  `auth.json` and `extensions/` are absent, and `settings.json`/`models.json` are
  read-only.
- ~~A session can read every past transcript on the machine~~ — fixed in both
  wrappers. `pi-sandbox.sh` mounts only the dir for its own cwd;
  `paseo-sandbox.sh` mounts only session dirs whose workspace is inside
  `~/Projects`. Add extra workspaces with `PI_SANDBOX_SESSIONS_RW=a:b` when a
  launcher starts in a directory whose dir does not exist yet.
- Paseo's state is readable by the agent it spawns, because both live in the same
  namespace (see "The two sandboxes cannot nest"). It is now inside `~/Projects`,
  so it is at least inside the boundary you audit — but the daemon credential is
  still readable from a session.
- **Write-side pivot (the reason for the fix above).** `~/.pi/agent/extensions/*.ts`
  is auto-discovered globally and runs with full host permissions. With the whole
  agent directory writable, sandboxed code could drop an extension there and the
  next *unsandboxed* `pi` on the host would load and execute it — a persistent
  escape, worse than reading `auth.json`. Verified after the fix: `settings.json`
  writes are refused and `extensions/` cannot reach the host (it can be created
  only inside the sandbox's tmpfs `~`, and vanishes on exit).
- If `tomykho` ever gets passwordless `sudo`, that does **not** open a hole:
  bubblewrap sets `no_new_privs`, so setuid escalation is dead inside the sandbox
  (`sudo: The "no new privileges" flag is set`). Verified above.
- Anything you bind rw (including `PI_SANDBOX_EXTRA`) is fair game.
- A compromised OmniRoute or a model-side prompt injection can still delete the
  project tree. That is what backups and git are for.
