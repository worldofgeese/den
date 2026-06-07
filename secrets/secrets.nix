let
  paphos = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPF9421ttFcrXv0Z4bwruLH2nXfDVsMO3SNxYE7aMJJ8";
  kypris = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKmz+S865IyQMVYIxsCy7iezQ3oGdPQeumZtHd2zQ2E3";
  tao-rsa = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDiFcUsDjnI0HHY5+5vYZrqFRCYIV1jay2Yv2QXSOQdKgTOPDsvYIofnNqOsh9a6euNc4w7Uc5whc2ZAivYfQpu8hV9oU9gkdNK17k1wQ39akoplurXiQUFBs7dIVvArMxejPkBLbvwZUBQrkS5F8ldQkFSX+MVU+J+a6SVHQDcfnQMDzfvkSfy84zPxtL4cBtS81zNN8vwH8wIWdqZZMLqo8DiiYfHn4WU+TiPwSpTjKfcaQi8/2podOYlrRcthuiAj/adgTGJnCxXHLFWuYOhXq8ty1E6db/fqJB5/h8ZfQxI1BgTWvQZ7WolbRvJsnplaE0hmxSmdWvKx9YVYT8FO3JCBAqPFQGxYUfdtusTyy3Dix8uo9osRGV4IdQ+e1Vz4pehmbgyXuTH/efWE09vhMa5k5CPY61v7Y7voeK4XNUcNmppBt0xtgnzidjMVv7hbpplLQRLQR4T/oJ7z2cMzfgQJUrSL0EkH9JUEh8hmho9sy09W0O1YBRbRQGPs02fCmWNUJBpJU2ZR2E0L9eGTha6FA8aj5Hya6n+bpNUf8nFWpalrRbyN2KsrpcuZmnuZ91fwPP6DEL5XNC2UQHHp0sAENz8dAlZmFFqCK0RoF1sWRD+DvYdhkdjGg0toRZVcUJgQTzzbQ81zoEtw8jqKS9YfRHVWK3yAUo/j4ddIQ==";
  tao-ed1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbIQYGvgicAePeJgXJY2wTFMjna8zHSIfqppFB0edOV";
  tao-ed2 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAiVMF2Pv1UXd2rkxEgz1E7Wgdt8MXn4yDQ+/dSthrfy";
  tao-ed3 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGQr88Pnz4YS8whUc6n2mtMeho/sNPqA9sDVzfAFxZH8";
  allKeys = [paphos kypris tao-rsa tao-ed1 tao-ed2 tao-ed3];
in {
  "forgejo-admin-password.age".publicKeys = allKeys;
  "forgesync-forgejo-token.age".publicKeys = allKeys;
  "forgesync-github-pat.age".publicKeys = allKeys;
  "aws-access-key-id.age".publicKeys = allKeys;
  "aws-secret-access-key.age".publicKeys = allKeys;
  "mediawiki-bot-password.age".publicKeys = allKeys;
  "mochi-api-key.age".publicKeys = allKeys;
  "skillsmp-api-key.age".publicKeys = allKeys;
  "groq-api-key.age".publicKeys = allKeys;
  "telegram-lbob-bot-token.age".publicKeys = allKeys;
  "paphos-mother-backup-ssh-key.age".publicKeys = allKeys;
  "surge-email.age".publicKeys = allKeys;
  "surge-password.age".publicKeys = allKeys;
}
