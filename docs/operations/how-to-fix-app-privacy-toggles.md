# How to fix a macOS privacy toggle that keeps turning itself off

Use this when a Nix-built app (WezTerm) loses **App Management** or **Full Disk
Access**: you switch it on in System Settings and it is off again later, or
`brew bundle` / Home Manager's `copyApps` fails with `Operation not permitted`
on another app's bundle.

## Fix it

```sh
just heal-app-permissions      # or, after a deploy: hm-app-signing heal
```

Then, once:

1. In the **App Management** list that opens, turn the app on. If it is not
   listed, click **+** and pick it from the Finder window that opened.
2. Accept **Quit & Reopen**.
3. Check it stuck:

   ```sh
   just app-permissions-status   # or: hm-app-signing status
   ```

   Expect `stable (grants survive rebuilds)` and `App Management: working`.

`heal` also clears Full Disk Access for the app. Re-enable it under
**Privacy & Security → Full Disk Access** if you use it.

## Why it happens

Nix signs apps *ad hoc*. An ad-hoc app's designated requirement is the cdhash
of that exact build:

```text
# designated => cdhash H"a052b4436fd8703802013acd4f931c1cffb0b033"
```

tccd stores a grant against that requirement. After a rebuild the running app
has a different cdhash, so tccd logs `Failed to match existing code requirement`,
denies the request, and recreates the entry as denied. That is the toggle
"turning itself off". Nothing managed the setting: tccd reported
`has no MDM records for service: kTCCServiceSystemPolicyAppBundles`.

`scripts/hm-app-signing.sh` re-signs the app with a local certificate, which
makes the requirement independent of the build:

```text
designated => identifier "com.github.wez.wezterm" and certificate leaf = H"…"
```

A grant made against that survives every later rebuild.

## How it stays fixed

- `home.activation.signHomeManagerApps` runs `hm-app-signing sign --activation`
  after `copyApps` on every deploy. `copyApps` rsyncs the ad-hoc build back over
  the app each time; re-signing restores the same requirement.
- `--activation` turns every failure into a warning. A failing activation step
  aborts the rest of nix-darwin activation, including Home Manager.
- The key lives in `~/Library/Keychains/hm-app-signing.keychain-db`, not the
  login keychain. Its password is `HM_APP_SIGNING_KEYCHAIN_PASSWORD` in
  secretspec, and `codesign` is pre-authorised, so signing never raises a
  dialog. The keychain is never left on the search list or unlocked.

## Watch it happen

```sh
log show --last 30m --style compact \
  --predicate 'process == "tccd" AND eventMessage CONTAINS[c] "AppBundles"'
```

## If a dialog asks for a keychain password

Click **Cancel**. The `hm-app-signing` keychain has a random password, not your
login password. A locked keychain raises that dialog when something queries it
directly. If `setup` ever reports that the stored password does not open the
keychain, delete it and re-run:

```sh
security delete-keychain ~/Library/Keychains/hm-app-signing.keychain-db
hm-app-signing setup && hm-app-signing sign
```

## Add another app

Edit the `APPS` default in `scripts/hm-app-signing.sh` (newline-separated
bundle paths), so both the activation hook and `heal` pick it up. For a one-off
run, `HM_APP_SIGNING_APPS` in the environment replaces that list entirely.
