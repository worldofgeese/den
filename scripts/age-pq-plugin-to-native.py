#!/usr/bin/env python3
"""Convert an age-plugin-pq identity (AGE-PLUGIN-PQ-1...) back to its native
form (AGE-SECRET-KEY-PQ-1...), so `age-keygen -y` can print its recipient.

age-plugin-pq's `-identity` only goes native -> plugin, and `age-keygen -y`
rejects the plugin form. The two carry the same key bytes and differ only in
the Bech32 prefix and checksum, so the conversion is a re-encode.
`just secretspec-se-setup` uses this to recover the backup recipient from the
backed-up identity. The key is read from stdin and written to stdout only.
"""
import sys

CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def polymod(values):
    gen = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]
    chk = 1
    for v in values:
        top = chk >> 25
        chk = (chk & 0x1FFFFFF) << 5 ^ v
        for i in range(5):
            chk ^= gen[i] if (top >> i) & 1 else 0
    return chk


def hrp_expand(hrp):
    return [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp]


def main():
    s = sys.stdin.read().strip().lower()
    sep = s.rfind("1")
    hrp, data = s[:sep], [CHARSET.index(c) for c in s[sep + 1 :]]
    if hrp != "age-plugin-pq-" or polymod(hrp_expand(hrp) + data) != 1:
        sys.exit("not a valid AGE-PLUGIN-PQ-1 identity")
    payload = data[:-6]
    new_hrp = "age-secret-key-pq-"
    mod = polymod(hrp_expand(new_hrp) + payload + [0] * 6) ^ 1
    checksum = [(mod >> 5 * (5 - i)) & 31 for i in range(6)]
    print((new_hrp + "1" + "".join(CHARSET[d] for d in payload + checksum)).upper())


if __name__ == "__main__":
    main()
