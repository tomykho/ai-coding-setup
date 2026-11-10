# gh-mint — deferred work

The broker is built, installed, tested (36 checks) and running as
`gh-mint.service`. **No owner is configured yet, so the sandbox is still in
`legacy` mode**: `gh`/`git` inside behave exactly as they did before this
directory existed, with the host's token and `~/.config/gh` bound writable.
Nothing here is half-finished or needs undoing — it is off, and it turns itself on
the moment one `apps/<owner>.env` or one `tokens/<owner>` exists.

The call as of writing: per-owner credential routing (App vs PAT vs org map) is
more machinery than the problem deserves right now. Keep the code, skip the setup.

## Open

- [ ] **One App for `tomykho`.** Everything except one number is done: the key is
      at `~/.config/gh-mint/keys/tomykho.pem` (0600, verified RSA-2048), the unit
      is enabled, the shim and helper are installed.
      Blocked on the **App ID** from `https://github.com/settings/apps/<slug>`.
      Unpark:
      ```bash
      ~/.config/gh-mint/gh-mint.sh installations     # needs APP_ID first
      # write apps/tomykho.env (APP_ID, INSTALL_ID, KEY_FILE), chmod 600
      ~/.config/gh-mint/gh-mint.sh check
      systemctl --user restart paseo.service         # picks up the new mode
      ```
      Permissions to grant: Contents RW, Pull requests RW (+ Workflows RW only if
      the agent may edit `.github/workflows/`). **Administration: No access** —
      that omission is what stops a leaked token from deleting a repo or
      unprotecting `main`. Install on **selected repositories**, never all.

- [ ] **`essedigital`.** Someone else's *personal* account, access granted as a
      collaborator. An App cannot be installed there by you — a private App
      installs only on its owner's account, and installation is the owner's click.
      The implemented answer is a fine-grained PAT served by the same socket
      (`tokens/<owner>`, read host-side per request, never mounted, never cached),
      which is what exists so it does not need a second design later.
      Two ways to unpark, pick one:
      1. ask the account owner to install the App (needs public visibility), or
      2. create a fine-grained PAT: resource owner you, **only select
         repositories**, Contents RW + PRs RW, everything else No access, expiry as
         long as you will tolerate —
         `install -m 600 /dev/null ~/.config/gh-mint/tokens/essedigital` then write
         the token, then `gh-mint.sh check --owner essedigital`.
      Trade to accept first: a PAT has no hourly re-mint, so its repo list and
      expiry are the whole boundary.

- [ ] **Public or private App** (only matters for orgs). One *public* App = one key
      for every owner you administer — `esseplore`, `gank-global`, `TeaGIF` — but
      anyone may install it, and the key holder can then mint for all of those
      installations. *Private* means one App per owner (one `.env` + one key each).
      Both are supported; nothing else changes either way. Employer-owned repos are
      out of scope in every variant.

- [ ] **Rulesets on the repos that matter** — require a PR before merge, block
      force-push, block deletion, and do **not** put the App on the bypass list.
      This is the control that actually bounds a hijacked session: no credential
      scheme stops an agent that legitimately has push access from pushing a
      backdoor onto a branch. `tomykho/ai-coding-setup` currently has none:
      `gh api repos/tomykho/ai-coding-setup/rulesets` → `[]`.

## Deliberately not doing

- SSH keys in the sandbox: account-wide, no expiry, copyable — strictly worse than
  a scoped HTTPS credential. Hence `GIT_SSH_COMMAND=/bin/false`.
- `gh auth login --with-token` inside the sandbox: writes the token to the host's
  git/gh config and defeats the point.
- Binding `~/.config/gh-mint` (keys) or `tokens/` into the namespace. The socket is
  the only interface, on purpose.
- A credential allowlist in front of `gh`: bypassable with `curl` and a sibling
  token file. The bound has to come from the credential itself.

## Unchanged by any of the above

- Commits keep the real author: `GIT_AUTHOR_*`/`GIT_COMMITTER_*` are set by the
  launchers, so swapping credentials never rewrites who wrote the code. An App does
  change the *server-side actor* (pusher, PR author, GitHub-created merge commits
  become `<app>[bot]`); a PAT keeps it as you.
- `/etc/ssh/ssh_config.d` mask and the https rewrite stay as they are.
- Rollback, always available: `PI_SANDBOX_GH=legacy pi-sandbox`, or suspend the App
  (kills minting for every sandbox), or `systemctl --user disable --now gh-mint`.
