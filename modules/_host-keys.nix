# SSH host public keys of the den servers, defined once.
# paphos: its agenix identity (secrets/secrets.nix), and the client key its
#   oracle checks present to upgrade-status@oracle.
# oracle: pinned in paphos' known_hosts for those checks.
# mother: the Synology NAS, SSH on port 2235. Pinned in paphos' known_hosts
#   for the Forgejo backup. Three sources agreed on 2026-11-01: a LAN key scan
#   from paphos, the key that paphos had accepted for the MagicDNS name, and
#   SHA256:CQfFLRGxoJrNR1uoDvglj/0qBn5b0xye17ptvXpV05Q from QuickWolf.
{
  paphos = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPF9421ttFcrXv0Z4bwruLH2nXfDVsMO3SNxYE7aMJJ8";
  oracle = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKcX0oCEvoJKK7S8KZnD0FVlYMM8sjhHj1RYZWPFG4TD";
  mother = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII3RJmlwFcHFbnf3CR0z87tJryhhNXlC3SQLRiCayrDz";
}
