#!/usr/bin/env bash
# gh-mint.sh — mint short-lived, repo-scoped GitHub tokens for a sandbox.
#
# The sandbox never holds a long-lived GitHub credential. A host-side process
# (gh-mint.service) holds the GitHub App private keys and answers one question
# over a unix socket: "give me a token for owner X". Every answer is an
# installation token: valid for 60 minutes, limited to the App's installed
# repositories, limited to the permissions the App was granted, and mintable
# again on demand. Nothing in the sandbox can widen it.
#
#   gh-mint.sh install            install this dir to ~/.config/gh-mint + unit
#   gh-mint.sh installations [O]  list the App's installations (find INSTALL_ID)
#   gh-mint.sh token [--owner O] [--json]   mint a token
#   gh-mint.sh check [--owner O]  verify key, App, installation and scope
#   gh-mint.sh owners             list configured owners and how each is served
#   gh-mint.sh serve              run the socket broker (gh-mint.service)
#
# Two kinds of owner, same socket, same shim, same helper:
#
#   App   you own the account or the org, so you can install an App on it:
#         60-minute installation tokens, nothing to rotate.
#   token a fine-grained PAT in $GH_MINT_HOME/tokens/<owner>, for repos where
#         you are only a collaborator (another user's account: no App can be
#         installed there by you). Long-lived, so the PAT's own repo list and
#         expiry are the boundary. The broker serves the file, so the token
#         never enters the sandbox at rest.
#
# Configuration: $GH_MINT_HOME/apps/<owner>.env, one file per App, each:
#
#   APP_ID=123456                    # App settings page
#   INSTALL_ID=78901234              # gh-mint.sh installations
#   KEY_FILE=~/.config/gh-mint/keys/<owner>.pem   # chmod 600, host-only
#   REPOS=repo-a,repo-b              # optional: narrow below the installation
#   PERMISSIONS=contents:write,pull_requests:write   # optional: narrow further
#
# REPOS/PERMISSIONS must be a subset of what the App was granted (GitHub answers
# 422 otherwise). Leaving them empty means "everything the App can do", which is
# already bounded by the installation.
set -uo pipefail

ME=${0##*/}
MINT_HOME=${GH_MINT_HOME:-$HOME/.config/gh-mint}
APPS=$MINT_HOME/apps
TOKENS=$MINT_HOME/tokens
API=${GH_MINT_API:-https://api.github.com}
SOCK=${GH_MINT_SOCK:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/gh-mint/gh-mint.sock}

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '%s: %s\n' "$ME" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ── JWT (RS256, 10-minute max per GitHub) ───────────────────────────────────
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

sign_jwt() { # sign_jwt <key file> <app id>
  local key=$1 app=$2 now h p
  now=$(date +%s)
  h=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
  p=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$app" | b64url)
  printf '%s.%s.%s' "$h" "$p" \
    "$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$key" | b64url)"
}

# ── app config ──────────────────────────────────────────────────────────────
load_app() { # load_app <owner>
  local f=$APPS/$1.env m
  [ -f "$f" ] || die "no App configured for owner '$1' (expected $f)"
  APP_ID='' INSTALL_ID='' KEY_FILE='' REPOS='' PERMISSIONS=''
  # shellcheck disable=SC1090  # a per-app config file chosen at runtime
  . "$f"
  [ -n "${APP_ID:-}" ] && [ -n "${INSTALL_ID:-}" ] && [ -n "${KEY_FILE:-}" ] ||
    die "$f must set APP_ID, INSTALL_ID and KEY_FILE"
  # shellcheck disable=SC2088  # a literal ~/ in the config file, expanded by hand
  case $KEY_FILE in "~/"*) KEY_FILE=$HOME/${KEY_FILE#\~/} ;; esac
  [ -r "$KEY_FILE" ] || die "private key not readable: $KEY_FILE"
  m=$(stat -c %a "$KEY_FILE" 2>/dev/null || echo 600)
  if (( (8#$m & 8#077) != 0 )); then
    warn "$KEY_FILE is accessible to group/other (mode $m); chmod 600 it"
  fi
}

resolve_owner() { # resolve_owner [owner]
  local o=${1:-${GH_MINT_OWNER:-}} f files=() names=()
  if [ -n "$o" ]; then printf '%s' "$o"; return 0; fi
  for f in "$APPS"/*.env "$TOKENS"/*; do
    [ -f "$f" ] || continue
    files+=("$f")
    names+=("$(basename "${f%.env}")")
  done
  case ${#files[@]} in
    1) printf '%s' "${names[0]}" ;;
    0) die "no owner configured in $MINT_HOME (see '$ME install')" ;;
    *) die "several owners configured (${names[*]}); pass --owner or set GH_MINT_OWNER" ;;
  esac
}

have_app() { [ -f "$APPS/$1.env" ]; }
have_token() { [ -s "$TOKENS/$1" ]; }

static_token() { # static_token <owner>: the PAT for an owner no App can serve
  local f=$TOKENS/$1 mode t
  [ -s "$f" ] || return 1
  mode=$(stat -c '%a' "$f" 2>/dev/null || echo '?')
  case $mode in
    600 | 400) ;;
    *) warn "$f is mode $mode -- chmod 600 it; a PAT others can read is not a secret" ;;
  esac
  t=$(tr -d '[:space:]' <"$f")
  [ -n "$t" ] || die "$f is empty"
  printf '%s' "$t"
}

# ── JSON helpers (a comma list in, a JSON fragment out) ─────────────────────
json_list() { # json_list 'a,b'
  local IFS=, out='' e
  for e in $1; do
    [ -n "$e" ] || continue
    out="${out:+$out,}\"$e\""
  done
  printf '[%s]' "$out"
}
json_map() { # json_map 'k:v,k:v'
  local IFS=, out='' e
  for e in $1; do
    [ -n "$e" ] || continue
    out="${out:+$out,}\"${e%%:*}\":\"${e#*:}\""
  done
  printf '{%s}' "$out"
}

# ── mint ────────────────────────────────────────────────────────────────────
cmd_token() {
  local owner='' json='' parts='' jwt resp code tok cur=()
  while [ $# -gt 0 ]; do
    case $1 in
      --owner) owner=$2; shift 2 ;;
      --json) json=1; shift ;;
      *) die "token: unknown argument $1" ;;
    esac
  done
  owner=$(resolve_owner "${owner:-}") || exit 1

  # An owner no App can be installed on (another user's account, where you are
  # only a collaborator) is served from a fine-grained PAT instead.
  if ! have_app "$owner" && have_token "$owner"; then
    tok=$(static_token "$owner") || die "could not read $TOKENS/$owner"
    if [ -n "$json" ]; then
      printf '{"owner":"%s","kind":"pat","expires_at":"","token":"%s"}\n' \
        "$owner" "$tok"
    else
      printf '%s' "$tok"
    fi
    return 0
  fi

  load_app "$owner"

  [ -n "$REPOS" ] && parts="\"repositories\":$(json_list "$REPOS")"
  [ -n "$PERMISSIONS" ] &&
    parts="${parts:+$parts,}\"permissions\":$(json_map "$PERMISSIONS")"
  cur=(--data "{$parts}") # '{}' means "everything the installation allows"

  jwt=$(sign_jwt "$KEY_FILE" "$APP_ID") || die "could not sign a JWT with $KEY_FILE"

  resp=$(curl -sS -X POST \
    -H "Authorization: Bearer $jwt" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    -w $'\n%{http_code}' \
    "${cur[@]}" \
    "$API/app/installations/$INSTALL_ID/access_tokens") || die "request to $API failed"

  code=${resp##*$'\n'}
  resp=${resp%$'\n'*}
  case $code in
    200 | 201) ;;
    401) die "401 rejected JWT: check APP_ID ($APP_ID) and that KEY_FILE ($KEY_FILE) is that App's key" ;;
    404) die "404: installation $INSTALL_ID not found for app $APP_ID — an uninstalled App, or a deleted install" ;;
    422) die "422 $(printf '%s' "$resp" | jq -r '.message // ""'): REPOS/PERMISSIONS in $APPS/$owner.env must be a subset of what the App was granted" ;;
    *) die "HTTP $code: $(printf '%s' "$resp" | jq -r '.message // empty' 2>/dev/null || printf '%s' "$resp")" ;;
  esac

  if [ -n "$json" ]; then
    printf '%s\n' "$resp"
  else
    printf '%s' "$resp" | jq -er '.token' || die "no token in the response: $resp"
  fi
}

cmd_installations() { # cmd_installations [--owner O]: needs only APP_ID + key
  local owner='' jwt
  while [ $# -gt 0 ]; do
    case $1 in
      --owner) owner=$2; shift 2 ;;
      *) die "installations: unknown argument $1" ;;
    esac
  done
  owner=$(resolve_owner "${owner:-}") || exit 1
  load_app "$owner"
  jwt=$(sign_jwt "$KEY_FILE" "$APP_ID") || die "could not sign a JWT with $KEY_FILE"
  curl -sS -H "Authorization: Bearer $jwt" -H 'Accept: application/vnd.github+json' \
    "$API/app/installations" |
    jq -r '.[] | "\(.id)\t\(.account.login)\t\(if .repository_selection == "all" then "all repos" else "selected repos" end)"' ||
    die "could not list installations for app $APP_ID"
  printf '\nApp %s, keys in %s\n' "$APP_ID" "$APPS/$owner.env"
}

cmd_check() { # cmd_check [--owner O]
  local owner='' out t acct repos
  while [ $# -gt 0 ]; do
    case $1 in
      --owner) owner=$2; shift 2 ;;
      *) die "check: unknown argument $1" ;;
    esac
  done
  owner=$(resolve_owner "${owner:-}") || exit 1

  if ! have_app "$owner" && have_token "$owner"; then
    t=$(static_token "$owner") || die "could not read $TOKENS/$owner"
    say "owner $owner -> static token $TOKENS/$owner ($(stat -c '%a %U' "$TOKENS/$owner"))"
    say "api   $API"
    acct=$(curl -sS -H "Authorization: Bearer $t" \
      -H 'Accept: application/vnd.github+json' -w $'\n%{http_code}' "$API/user")
    case ${acct##*$'\n'} in
      200) ;;
      401) die "401: the token is rejected -- expired, revoked, or the file is wrong" ;;
      *) die "HTTP ${acct##*$'\n'} from $API/user" ;;
    esac
    acct=${acct%$'\n'*}
    say "login $(printf '%s' "$acct" | jq -r .login), token ${t:0:11}... (${#t} chars)"
    acct=$(curl -sS -H "Authorization: Bearer $t" \
      -H 'Accept: application/vnd.github+json' \
      "$API/user/repos?per_page=100&affiliation=owner,collaborator,organization_member")
    repos=$(printf '%s' "$acct" | jq -r 'if type == "array" then length else 0 end' 2>/dev/null)
    say "scope $repos repo(s): $(printf '%s' "$acct" | jq -r '[.[].full_name] | join(", ")' 2>/dev/null)"
    warn "a PAT does not die in an hour: its repo selection and expiry date are the boundary"
    warn "rotate by overwriting $TOKENS/$owner -- the broker reads it per request, no restart"
    return 0
  fi

  load_app "$owner"

  say "owner $owner -> app $APP_ID, install $INSTALL_ID"
  say "key   $KEY_FILE ($(stat -c '%a %U' "$KEY_FILE" 2>/dev/null))"
  say "api   $API"

  out=$(cmd_token --owner "$owner" --json) || exit 1
  t=$(printf '%s' "$out" | jq -er '.token') || die "no token in the response"
  say "token ${t:0:11}... (${#t} chars), expires $(printf '%s' "$out" | jq -r '.expires_at') (60 min hard limit)"

  acct=$(curl -sS -H "Authorization: Bearer $t" -H 'Accept: application/vnd.github+json' \
    -w $'\n%{http_code}' "$API/installation/repositories")
  case ${acct##*$'\n'} in
    200) ;;
    *) die "the minted token did not work: HTTP ${acct##*$'\n'}" ;;
  esac
  acct=${acct%$'\n'*}
  repos=$(printf '%s' "$acct" | jq -r '.repositories | length')
  say "scope $repos repo(s): $(printf '%s' "$acct" | jq -r '[.repositories[].full_name] | join(", ")')"
  say "granted: $(printf '%s' "$out" | jq -rc '.permissions')  <- cannot exceed this"
  say "ok. A leaked token dies within the hour and cannot leave those repos."
}

cmd_serve() {
  have python3 || die "serve needs python3"
  GH_MINT_BIN=$MINT_HOME/gh-mint.sh
  [ -x "$GH_MINT_BIN" ] || GH_MINT_BIN=$(readlink -f "${BASH_SOURCE[0]}")
  export GH_MINT_BIN GH_MINT_HOME
  exec python3 "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/gh-mint-serve.py" "$SOCK"
}

cmd_owners() { # what the broker can serve, and how
  local f n
  for f in "$APPS"/*.env; do
    [ -f "$f" ] || continue
    n=${f##*/}
    printf '%-20s app    id=%s install=%s\n' "${n%.env}" \
      "$(sed -n 's/^APP_ID=//p' "$f" | head -1)" \
      "$(sed -n 's/^INSTALL_ID=//p' "$f" | head -1)"
  done
  for f in "$TOKENS"/*; do
    [ -f "$f" ] || continue
    printf '%-20s token  PAT, %s bytes, mode %s\n' "${f##*/}" \
      "$(wc -c <"$f")" "$(stat -c '%a' "$f")"
  done
}

cmd_install() {
  local here dst=$MINT_HOME unit=$HOME/.config/systemd/user/gh-mint.service
  here=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
  mkdir -p "$APPS" "$TOKENS" "$dst/bin" "$MINT_HOME/keys"
  chmod 700 "$MINT_HOME" "$APPS" "$TOKENS" "$MINT_HOME/keys"
  install -m 0755 "$here/gh-mint.sh" "$dst/gh-mint.sh"
  install -m 0644 "$here/gh-mint-serve.py" "$dst/gh-mint-serve.py"
  install -m 0755 "$here/bin/gh" "$here/bin/gh-mint-credential" "$dst/bin/"
  install -m 0644 "$here/gh-mint.service" "$unit"
  say "installed $dst and $unit"
  if [ -f "$here/gh-mint.service" ] && have systemctl; then
    systemctl --user daemon-reload
    systemctl --user enable --now gh-mint.service 2>/dev/null ||
      warn "could not start gh-mint.service (no Apps configured yet?); start it after adding one"
    say "unit: $(systemctl --user is-active gh-mint.service 2>/dev/null || echo inactive)"
  fi
  cat <<EOF

Next, one file per GitHub App (see sandbox/README.md, "GitHub access"):

  $APPS/<owner>.env     APP_ID=…  INSTALL_ID=…  KEY_FILE=$MINT_HOME/keys/<owner>.pem
  chmod 600 $MINT_HOME/keys/<owner>.pem

then:  $dst/gh-mint.sh installations   and   $dst/gh-mint.sh check

For an owner that no App can be installed on (another user's account, where you
are a collaborator), write a fine-grained PAT instead -- it gets the same socket:

  chmod 600 $TOKENS/<owner>     # one line: github_pat_...
EOF
}

usage() {
  sed -n '3,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case ${1:-} in
  token) shift; cmd_token "$@" ;;
  installations) shift; cmd_installations "$@" ;;
  check) shift; cmd_check "$@" ;;
  owners) shift; cmd_owners "$@" ;;
  serve) shift; cmd_serve "$@" ;;
  install) shift; cmd_install "$@" ;;
  -h | --help | help) usage ;;
  *) usage; exit 2 ;;
esac
