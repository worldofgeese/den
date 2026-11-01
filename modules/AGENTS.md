# Review rules for modules/

The Codex connector reviews den's pull requests, and it follows the
`## Code Review Rules` of each `AGENTS.md` that covers a changed file. The
root `AGENTS.md` is a Decapod template, and a hand edit fails validation, so
den keeps its review rules in this file.

## Code Review Rules

### Secrets

- Flag a change that puts a secret value into a Nix expression, the Nix store
  or a committed file in plain text. Each user of a host can read the Nix
  store, and the repository is public.
  Safe path: an agenix file in `secrets/` or a secretspec secret, which the
  host reads at activation or at run time.

### Remote access to the servers

- Flag a change to SSH, Tailscale, the firewall or the users of `paphos` or
  `oracle` that can remove the last way to log in remotely. Both servers
  upgrade themselves from `main`, so a lockout also stops the next fix.
  Safe path: keep one SSH path and its key that work, while the change
  replaces another path.

### Exposure of oracle

- Flag a change that opens a port on the public interface of `oracle`, or
  that widens a `NOPASSWD` sudo rule on any host. `oracle` is on the public
  internet with ports 22, 80 and 443.
  Safe path: bind a new service to the tailnet or to localhost, and name the
  exact command in a sudo rule.
