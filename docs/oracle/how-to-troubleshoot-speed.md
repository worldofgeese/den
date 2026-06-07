# How-to: Troubleshoot tailnet speed

Use this when transfers between tailnet nodes are slow, or you suspect DERP instead of direct or peer-relay paths.

## Scope by host

| Host | Role in speed work |
|------|-------------------|
| **oracle** | Tailscale **peer relay** (UDP 40000) — not BBR tuning |
| **loving-kypris** | BBR + OpenSpeedtest (deploy on host separately) |
| **mother** | OpenSpeedtest only — **BBR not available** (Synology kernel 4.4; see [explanation](explanation-network-design.md)) |

## 1. Measure with OpenSpeedtest

Run OpenSpeedtest on a stable LAN or tailnet endpoint, then test from the client.

On **loving-kypris** or **mother** (after service is deployed on those hosts):

- Open the OpenSpeedtest UI in a browser (port depends on your deployment; commonly 3000 or 8080).
- From the slow client, run a test to that host over Tailscale MagicDNS (e.g. `loving-kypris.hound-celsius.ts.net`).

Record: download/upload Mbps and latency. Repeat after path changes.

## 2. Check connection path

On the client:

```bash
tailscale status
tailscale ping -verbose TARGET_HOST
tailscale netcheck
```

Interpretation:

| Path indicator | Meaning |
|----------------|---------|
| `direct` | WireGuard direct — best case |
| `peer-relay IP:40000` | Traffic via oracle (or another relay) |
| `derp` / region name | Relay through Tailscale DERP — often capped throughput |

If you expect peer-relay but see DERP, check oracle UDP 40000 (NixOS firewall + OCI security list), relay grants, and Tailscale ≥ 1.86 on all nodes.

## 3. Check BBR (loving-kypris only)

On a Linux host where BBR is configured:

```bash
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
```

Expect `bbr` (or `bbr2` on newer kernels) and `fq` or `fq_codel`.

On **mother** (Synology DSM):

```bash
sysctl net.ipv4.tcp_available_congestion_control
```

Typical output: `reno cubic` only — no `tcp_bbr` module. Do not spend effort enabling BBR there; optimize paths (direct, peer-relay) instead.

## 4. Compare direct vs relay vs DERP

Controlled experiment:

1. Baseline: `tailscale ping -until-direct=false TARGET` (may force relay/derp).
2. Prefer direct: ensure both nodes can UDP punch (check `netcheck` NAT rating).
3. With oracle relay up: disconnect direct path (e.g. restrictive firewall test) and confirm `peer-relay` appears.
4. Re-run OpenSpeedtest for each path class.

## 5. Oracle relay checklist

On **oracle**:

```bash
sudo ss -ulnp | grep 40000
sudo tailscale set --relay-server-port=40000
```

From OCI: security list must allow UDP 40000 from `0.0.0.0/0` (or restrict to tailnet egress if you add tighter rules later).

## 6. When to change what

| Symptom | Likely cause | Action |
|---------|--------------|--------|
| Always `derp` | NAT/firewall blocks UDP | Fix port forwarding; enable peer-relay |
| `peer-relay` but low Mbps | Relay CPU/bandwidth or long RTT | Expect better than DERP; direct still faster if possible |
| Good direct, bad cross-region | Geography | Peer relay on oracle between regions |
| mother slow, loving-kypris fast | No BBR on Synology | Accept cubic; tune path not congestion control |

Further background: [explanation-network-design.md](explanation-network-design.md).
