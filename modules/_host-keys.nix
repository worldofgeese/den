# SSH host public keys of the den servers, defined once.
# paphos: its agenix identity (secrets/secrets.nix), and the client key its
#   oracle checks present to upgrade-status@oracle.
# oracle: pinned in paphos' known_hosts for those checks.
{
  paphos = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPF9421ttFcrXv0Z4bwruLH2nXfDVsMO3SNxYE7aMJJ8";
  oracle = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKcX0oCEvoJKK7S8KZnD0FVlYMM8sjhHj1RYZWPFG4TD";
}
