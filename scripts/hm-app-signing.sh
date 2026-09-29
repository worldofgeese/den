# hm-app-signing -- give Nix-built macOS apps a stable code-signing identity.
#
# Why: Nix signs apps ad hoc, so an app's designated requirement is the cdhash
# of that exact build. macOS privacy grants (App Management, Full Disk Access)
# are stored against that requirement, so every rebuild of WezTerm looked like a
# new app and tccd silently reset its grant to "denied" -- the toggle "turning
# itself off" (diagnosed from tccd logs on 2026-09-24).
#
# Signing with a local certificate changes the requirement to
#   identifier "<bundle id>" and certificate leaf = H"<this key>"
# which is identical across builds, so a grant made once survives rebuilds.
#
# Home Manager's copyApps rsyncs the ad-hoc build back over the app on every
# activation, so `sign` runs after it each time; the requirement stays the same.
#
# Subcommands:
#   setup    create the signing keychain and certificate (idempotent)
#   sign     sign the configured apps (idempotent); --activation never fails
#   heal     setup + sign + reset stale grants + open System Settings
#   status   show identity, per-app signature, and whether App Management works

readonly KEYCHAIN="${HOME}/Library/Keychains/hm-app-signing.keychain-db"
readonly CERT_CN="Home Manager Local Code Signing"
readonly SECRET_NAME="HM_APP_SIGNING_KEYCHAIN_PASSWORD"
readonly SECRETSPEC_FILE="${HM_APP_SIGNING_SECRETSPEC_FILE:-${HOME}/.config/home-manager/secretspec.toml}"
readonly SECURITY=/usr/bin/security
readonly CODESIGN=/usr/bin/codesign
readonly TCCUTIL=/usr/bin/tccutil
readonly OPEN=/usr/bin/open
readonly PLISTBUDDY=/usr/libexec/PlistBuddy
# Newline-separated bundle paths; the Nix wrapper sets this.
readonly APPS="${HM_APP_SIGNING_APPS:-${HOME}/Applications/Home Manager Apps/WezTerm.app}"
# TCC services whose stale grants `heal` clears. App Management is the one that
# breaks deploys (brew and copyApps both need it); Full Disk Access breaks the
# same way, so clear it too and let the user re-grant only what they want.
readonly HEAL_SERVICES="SystemPolicyAppBundles SystemPolicyAllFiles"

ACTIVATION=0
say() { printf 'hm-app-signing: %s\n' "$*" >&2; }
die() {
  say "error: $*"
  exit 1
}
# In activation mode a signing problem must never fail the whole deploy: a
# failed step aborts nix-darwin activation before later steps run (a failing
# brew bundle did exactly that on 2026-09-24).
soft_die() {
  if [ "$ACTIVATION" = 1 ]; then
    say "warning: $* -- skipping; run 'hm-app-signing heal' to repair"
    exit 0
  fi
  die "$*"
}

each_app() {
  local app
  while IFS= read -r app; do
    [ -n "$app" ] && printf '%s\n' "$app"
  done <<<"$APPS"
}

keychain_password() {
  secretspec get -f "$SECRETSPEC_FILE" "$SECRET_NAME" \
    --reason "hm-app-signing: unlock the local code-signing keychain" 2>/dev/null
}

identity_sha1() {
  [ -f "$KEYCHAIN" ] || return 0
  "$SECURITY" find-certificate -c "$CERT_CN" -Z "$KEYCHAIN" 2>/dev/null |
    awk '/^SHA-1 hash:/ { print $3; exit }'
}

# True when the app is signed by our certificate and the signature verifies.
stably_signed() {
  local app=$1 leaf
  leaf=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  "$CODESIGN" -d -r- "$app" 2>&1 | grep -qF "certificate leaf = H\"${leaf}\"" &&
    "$CODESIGN" --verify --deep --strict "$app" 2>/dev/null
}

# The signing identity (certificate + private key, as PKCS#12 encrypted with
# the keychain password) is escrowed in secretspec, so the keychain is only a
# cache. Privacy grants are pinned to the certificate, so losing it -- a
# keychain that stopped opening with its stored password on 2026-09-29 forced
# a new identity -- silently voids every grant. With the escrow, a keychain
# that is missing, will not unlock, or holds a different identity is rebuilt
# from it with the same certificate, and the grants keep applying.
readonly ESCROW_NAME="HM_APP_SIGNING_IDENTITY"

escrow_get() {
  secretspec get -f "$SECRETSPEC_FILE" "$ESCROW_NAME" \
    --reason "hm-app-signing: restore the local code-signing identity" 2>/dev/null
}

# SHA-1 of the escrowed certificate, the value codesign and `security` print.
escrow_sha1() {
  local b64=$1 pw=$2
  printf '%s' "$b64" | openssl base64 -d -A |
    openssl pkcs12 -legacy -nokeys -passin "pass:${pw}" 2>/dev/null |
    openssl x509 -noout -fingerprint -sha1 | sed 's/.*=//; s/://g'
}

ensure_password() {
  local pw
  pw=$(keychain_password || true)
  if [ -z "$pw" ]; then
    pw=$(openssl rand -base64 32 | tr -d '\n')
    printf '%s' "$pw" | secretspec set -f "$SECRETSPEC_FILE" "$SECRET_NAME" \
      --reason "hm-app-signing: store the signing keychain password" >/dev/null
    [ "$(keychain_password)" = "$pw" ] || die "could not store ${SECRET_NAME} in secretspec"
    say "stored a new keychain password as ${SECRET_NAME} in secretspec"
  fi
  printf '%s' "$pw"
}

# Recreate the keychain from a base64 PKCS#12 and the keychain password.
rebuild_keychain() {
  local b64=$1 pw=$2 tmp rc=0
  tmp=$(mktemp -d)
  (umask 077 && printf '%s' "$b64" | openssl base64 -d -A >"$tmp/id.p12")
  "$SECURITY" delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || rm -f "$KEYCHAIN"
  # The password is passed on argv here, visible to `ps` for a moment. This
  # keychain holds nothing but the local signing key, so that is acceptable.
  "$SECURITY" create-keychain -p "$pw" "$KEYCHAIN"
  chmod 600 "$KEYCHAIN"
  "$SECURITY" import "$tmp/id.p12" -k "$KEYCHAIN" -P "$pw" -T "$CODESIGN" >/dev/null || rc=1
  rm -rf "$tmp"
  [ "$rc" = 0 ] || return 1
  # Pre-authorise codesign so signing never raises a keychain dialog; this is
  # what lets `sign` run unattended during activation.
  "$SECURITY" set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" "$KEYCHAIN" >/dev/null
  "$SECURITY" lock-keychain "$KEYCHAIN"
  # Prove the stored password opens what was just built (2026-09-24, -29).
  "$SECURITY" unlock-keychain -p "$pw" "$KEYCHAIN" || return 1
  "$SECURITY" lock-keychain "$KEYCHAIN"
}

# Make the keychain hold the escrowed identity, unlockable with the stored
# password. Returns 1 when there is no escrow (only `setup` may mint one).
restore_from_escrow() {
  local pw b64 want
  pw=$1
  b64=$(escrow_get || true)
  [ -n "$b64" ] || return 1
  want=$(escrow_sha1 "$b64" "$pw")
  [ -n "$want" ] || soft_die "${ESCROW_NAME} does not open with ${SECRET_NAME}"
  if [ "$(identity_sha1)" = "$want" ] &&
    "$SECURITY" unlock-keychain -p "$pw" "$KEYCHAIN" 2>/dev/null; then
    "$SECURITY" lock-keychain "$KEYCHAIN"
    return 0
  fi
  say "keychain missing, locked out, or holding another identity; rebuilding it from ${ESCROW_NAME}"
  rebuild_keychain "$b64" "$pw" || soft_die "could not rebuild ${KEYCHAIN} from ${ESCROW_NAME}"
  [ "$(identity_sha1)" = "$want" ] || soft_die "restored identity does not match the escrow"
}

cmd_setup() {
  local pw tmp b64
  pw=$(ensure_password)
  if restore_from_escrow "$pw"; then
    say "signing identity present ($(identity_sha1)), escrowed as ${ESCROW_NAME}"
    return 0
  fi
  # No escrow yet: mint the identity once. Any grant made to an app signed by
  # an earlier, un-escrowed identity has to be made again after this.
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # expand $tmp now, not at exit
  trap "rm -rf '$tmp'" EXIT
  (
    umask 077
    openssl req -x509 -newkey rsa:3072 -nodes -days 7300 \
      -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -subj "/CN=${CERT_CN}" \
      -addext "basicConstraints=critical,CA:false" \
      -addext "keyUsage=critical,digitalSignature" \
      -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
    # -legacy: macOS `security import` cannot read OpenSSL 3's default PKCS#12.
    openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
      -out "$tmp/id.p12" -passout "pass:${pw}"
  )
  b64=$(openssl base64 -A -in "$tmp/id.p12")
  rm -rf "$tmp"
  trap - EXIT
  printf '%s' "$b64" | secretspec set -f "$SECRETSPEC_FILE" "$ESCROW_NAME" \
    --reason "hm-app-signing: escrow the local code-signing identity" >/dev/null
  [ "$(escrow_get)" = "$b64" ] || die "could not store ${ESCROW_NAME} in secretspec"
  restore_from_escrow "$pw" || die "escrowed identity did not restore"
  say "created signing identity '${CERT_CN}' ($(identity_sha1)), escrowed as ${ESCROW_NAME}"
}

cmd_sign() {
  local sha pw app todo=() original=() line
  pw=$(keychain_password || true)
  [ -n "$pw" ] || soft_die "could not read ${SECRET_NAME} from secretspec"
  # Repair the keychain from the escrow before anything else, so a broken
  # keychain never leaves an app ad-hoc signed (and its grants void).
  restore_from_escrow "$pw" || soft_die "no escrowed identity yet; run 'hm-app-signing setup'"
  sha=$(identity_sha1)
  [ -n "$sha" ] || soft_die "no signing identity yet"
  while IFS= read -r app; do
    if [ ! -d "$app" ]; then
      say "not installed, skipping: $app"
    elif stably_signed "$app" "$sha"; then
      say "already stably signed: $app"
    else
      todo+=("$app")
    fi
  done < <(each_app)
  [ "${#todo[@]}" -gt 0 ] || return 0

  "$SECURITY" unlock-keychain -p "$pw" "$KEYCHAIN" || soft_die "could not unlock ${KEYCHAIN}"

  # codesign only finds identities in keychains on the user search list. Add
  # ours for the duration and always put the list back: a locked keychain left
  # on the list makes other apps raise unlock prompts.
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line#\"}
    line=${line%\"}
    [ -n "$line" ] && original+=("$line")
  done < <("$SECURITY" list-keychains -d user)
  restore() {
    "$SECURITY" list-keychains -d user -s "${original[@]}"
    "$SECURITY" lock-keychain "$KEYCHAIN" 2>/dev/null || true
  }
  trap restore EXIT
  "$SECURITY" list-keychains -d user -s "${original[@]}" "$KEYCHAIN"

  local failed=0
  for app in "${todo[@]}"; do
    # In place is safe for a running app: codesign writes a new file and
    # renames it (verified: the executable's inode changes), like rsync does.
    if "$CODESIGN" --force --deep --sign "$sha" "$app" 2>/dev/null &&
      stably_signed "$app" "$sha"; then
      say "signed: $app"
    else
      say "warning: signing failed: $app"
      failed=1
    fi
  done
  restore
  trap - EXIT
  [ "$failed" = 0 ] || soft_die "one or more apps could not be signed"
}

# App Management governs modifying *other* apps' bundles, so probe with a
# foreign app this user owns: bump the mtime of its Info.plist (touch -c never
# creates; content, and so its signature, is unchanged).
probe_app_management() {
  local candidate team
  for candidate in /Applications/*.app; do
    [ -O "$candidate/Contents/Info.plist" ] || continue
    team=$("$CODESIGN" -dv "$candidate" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    if [ -z "$team" ] || [ "$team" = "not set" ]; then
      continue
    fi
    if touch -c "$candidate/Contents/Info.plist" 2>/dev/null; then
      printf 'working (probed %s)\n' "${candidate##*/}"
    else
      printf 'BLOCKED for this terminal (probed %s)\n' "${candidate##*/}"
    fi
    return 0
  done
  printf 'unknown (no user-owned, team-signed app in /Applications to probe)\n'
}

cmd_status() {
  local sha app dr
  sha=$(identity_sha1)
  printf 'identity:        %s\n' "${sha:-none -- run: hm-app-signing setup}"
  while IFS= read -r app; do
    if [ ! -d "$app" ]; then
      printf '%-16s not installed\n' "${app##*/}:"
      continue
    fi
    # Ad-hoc signatures print their implicit requirement as a comment.
    dr=$("$CODESIGN" -d -r- "$app" 2>&1 | sed -n 's/^#* *designated => //p')
    if [ -n "$sha" ] && stably_signed "$app" "$sha"; then
      printf '%-16s stable (grants survive rebuilds)\n' "${app##*/}:"
    else
      printf '%-16s NOT stable: %s\n' "${app##*/}:" "${dr:-unsigned}"
    fi
  done < <(each_app)
  printf 'App Management:  %s\n' "$(probe_app_management)"
}

cmd_heal() {
  local app bid svc
  cmd_setup
  cmd_sign
  while IFS= read -r app; do
    [ -d "$app" ] || continue
    bid=$("$PLISTBUDDY" -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
    for svc in $HEAL_SERVICES; do
      "$TCCUTIL" reset "$svc" "$bid" >/dev/null 2>&1 || true
    done
    say "cleared stale privacy grants for ${bid}"
    "$OPEN" -R "$app"
  done < <(each_app)
  "$OPEN" "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles"
  cat >&2 <<EOF

Now, once:
  1. In the App Management list that just opened, turn the app on. If it is
     not listed, click + and pick it from the Finder window that opened.
  2. Accept "Quit & Reopen". The running process still has the old ad-hoc
     identity until it restarts; the grant applies to the new one.
  3. After it reopens, run:  hm-app-signing status
     App Management should read "working" -- and stay that way across rebuilds.

Full Disk Access was cleared too: its old grant was pinned to a previous build
and no longer applied. If you want it, re-enable it once under Privacy &
Security > Full Disk Access; it will now survive rebuilds as well.
EOF
}

case "${1:-}" in
  setup) cmd_setup ;;
  sign)
    [ "${2:-}" = "--activation" ] && ACTIVATION=1
    cmd_sign
    ;;
  heal) cmd_heal ;;
  status) cmd_status ;;
  *)
    cat >&2 <<'EOF'
usage: hm-app-signing {setup|sign [--activation]|heal|status}
  heal    one-command repair when an app's privacy toggle keeps turning off
  status  check whether grants will survive the next rebuild
EOF
    exit 2
    ;;
esac
