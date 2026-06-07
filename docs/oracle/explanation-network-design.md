# Explanation: Network design choices

Why oracle runs peer relay only, how that relates to DERP, A2 bootstrap, and why BBR on mother is off the table.

## Peer relay vs DERP

Tailscale establishes WireGuard tunnels between nodes. When **direct UDP** fails (symmetric NAT, firewall, cross-region constraints), traffic must traverse a relay.

**DERP** (Designated Encrypted Relay for Packets) is Tailscale’s shared relay mesh. It is reliable and always available, but shared infrastructure can limit sustained throughput and adds latency.

**Peer relay** runs on **your** node (here: oracle on Oracle Cloud). Clients send encrypted WireGuard frames to the relay’s UDP port; the relay forwards between existing inbound sessions. It does not decrypt traffic. When configured and granted in policy, Tailscale prefers peer relay over DERP for eligible paths.

Oracle’s role in this fleet: a stable, publicly reachable UDP endpoint (UDP 40000) in the cloud — **not** an exit node and **not** a subnet router.

## Why oracle does not run BBR tuning

Congestion control (BBR) optimizes **TCP** behavior on the host’s own traffic. Oracle’s job is **UDP relay** for Tailscale. BBR on oracle would not meaningfully improve peer-relay forwarding (relay is UDP forward, not TCP termination). BBR work belongs on bulk-transfer endpoints such as **loving-kypris**.

## Why mother cannot use BBR

**mother** is a Synology NAS on DSM with Linux kernel **4.4.x**. That kernel predates mainline `tcp_bbr` and the module is not shipped on typical Synology builds. Available algorithms are usually:

```
net.ipv4.tcp_available_congestion_control = reno cubic
```

Enabling BBR would require a kernel with `tcp_bbr` (custom kernel or different platform). That is out of scope for DSM. Speed work on mother focuses on **path selection** (direct vs peer-relay vs DERP) and measurement (OpenSpeedtest), not congestion-control swaps.

## A2 bootstrap when A1 is unavailable

Oracle Always Free capacity for `VM.Standard.A1.Flex` is region- and time-dependent. Terraform may fail with **Out of host capacity**.

**Workaround:** temporarily launch on paid **`VM.Standard.A2.Flex`** during Free Trial:

1. Set `instance_shape = "VM.Standard.A2.Flex"` in `terraform.tfvars`.
2. `just oracle-tofu-plan` and `just oracle-tofu-apply`.
3. Verify SSH and NixOS boot.
4. Switch `instance_shape` back to `VM.Standard.A1.Flex` and re-apply when A1 capacity returns.

A2 is **not** Always Free — it consumes trial credits or incurs charges while running. The repo registers both shapes via `image_compatible_shapes` so the custom image works on either.

Image capability schema (UEFI_64, paravirtualized boot/network/storage) matches Oracle’s requirements for custom ARM images; if an instance hangs after boot, re-apply or refresh capability schema in the OCI console.

## End-to-end picture

```text
[ Client A ] ----wireguard----> [ oracle :40000 peer-relay ] ----> [ Client B ]
                     \                                              /
                      -------- direct UDP (preferred if possible) --
```

When direct works, traffic skips oracle. When it does not, grants allow oracle to relay before falling back to DERP.

**loving-kypris** and **mother** host OpenSpeedtest (deployed outside this bead) for empirical checks. **oracle** improves tailnet topology; **loving-kypris** improves TCP stack behavior where BBR is available.
