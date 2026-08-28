#
# paphos's authorized SSH keys, in one place.
#
# Underscore-prefixed so import-tree ignores it: this is data imported by
# modules/paphos/{hardware,system}.nix, not an aspect. The same five-key block was
# copy-pasted into both, so rotating or revoking a key meant editing two files
# that did not reference each other.
#
# Refs: home-manager-0pr.10
{
  # Remote keys. These both unlock the initrd (port 2222, modules/paphos/hardware.nix)
  # and log in as kypris (modules/paphos/system.nix).
  remote = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKmz+S865IyQMVYIxsCy7iezQ3oGdPQeumZtHd2zQ2E3 kypris"
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDiFcUsDjnI0HHY5+5vYZrqFRCYIV1jay2Yv2QXSOQdKgTOPDsvYIofnNqOsh9a6euNc4w7Uc5whc2ZAivYfQpu8hV9oU9gkdNK17k1wQ39akoplurXiQUFBs7dIVvArMxejPkBLbvwZUBQrkS5F8ldQkFSX+MVU+J+a6SVHQDcfnQMDzfvkSfy84zPxtL4cBtS81zNN8vwH8wIWdqZZMLqo8DiiYfHn4WU+TiPwSpTjKfcaQi8/2podOYlrRcthuiAj/adgTGJnCxXHLFWuYOhXq8ty1E6db/fqJB5/h8ZfQxI1BgTWvQZ7WolbRvJsnplaE0hmxSmdWvKx9YVYT8FO3JCBAqPFQGxYUfdtusTyy3Dix8uo9osRGV4IdQ+e1Vz4pehmbgyXuTH/efWE09vhMa5k5CPY61v7Y7voeK4XNUcNmppBt0xtgnzidjMVv7hbpplLQRLQR4T/oJ7z2cMzfgQJUrSL0EkH9JUEh8hmho9sy09W0O1YBRbRQGPs02fCmWNUJBpJU2ZR2E0L9eGTha6FA8aj5Hya6n+bpNUf8nFWpalrRbyN2KsrpcuZmnuZ91fwPP6DEL5XNC2UQHHp0sAENz8dAlZmFFqCK0RoF1sWRD+DvYdhkdjGg0toRZVcUJgQTzzbQ81zoEtw8jqKS9YfRHVWK3yAUo/j4ddIQ=="
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbIQYGvgicAePeJgXJY2wTFMjna8zHSIfqppFB0edOV"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAiVMF2Pv1UXd2rkxEgz1E7Wgdt8MXn4yDQ+/dSthrfy"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGQr88Pnz4YS8whUc6n2mtMeho/sNPqA9sDVzfAFxZH8"
  ];

  # kypris's key on paphos itself. Deliberately not in the initrd set: at initrd
  # stage the disk is still locked and you connect FROM another machine, so a key
  # that only exists on paphos cannot help. Keeping the asymmetry visible is the
  # point of splitting the two lists rather than merging them.
  local = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILDJoQwR2VX/GixAthlOPkA8kfGh+5wXF3mjd9lnwCUi kypris@paphos"
  ];
}
