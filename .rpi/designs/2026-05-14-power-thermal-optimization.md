---
status: active
date: 2026-05-14
topic: Power & thermal optimization for Dell XPS 13 9380
upstream: null
---

# Power & Thermal Optimization — Dell XPS 13 9380

## Context

Dell XPS 13 9380 (Intel i7-8565U Whiskey Lake, UHD 620, QCA6174 WiFi) running
Guix System with CachyOS kernel 6.18. Currently has **no power management
daemon** and kernel args that actively disable PCIe ASPM and i915 PSR.

Fans run 4400-4700 RPM at 47-57°C idle/light load. HWP EPP is
`balance_performance`, platform profile is `balanced`.

## Decision

Add **TLP + thermald** to `guix/system.scm`. Fix kernel arguments. Configure
TLP for the Dell XPS 13 **balanced** battery profile (revised 2026-11-27; see
"Battery mode revision" below).

### Why TLP over power-profiles-daemon

- TLP manages 40+ power knobs (ASPM, USB autosuspend, WiFi power save, audio
  codec sleep, SATA ALPM, runtime PM, CPU energy bias, disk APM, NMI watchdog)
- PPD is just a 3-mode profile switcher with no fine-grained control
- TLP has Dell-specific platform profile integration
- They conflict — can't run both

### Why thermald

- Intel's own thermal daemon for their CPUs
- Throttles CPU frequency/turbo gracefully *before* BIOS triggers fan ramp-up
- Specifically designed for Whiskey Lake and similar mobile parts
- Zero configuration needed — reads ACPI thermal tables automatically

## Changes

### 1. Kernel arguments (system.scm line 70)

Remove:
- `pcie_aspm=off` — re-enable PCIe link power management
- `i915.enable_psr=0` — re-enable Panel Self-Refresh

Add:
- `snd_hda_intel.power_save=1` — audio codec sleeps after 1s idle

### 2. New services (system.scm services block)

```scheme
(service thermald-service-type)

(service tlp-service-type
  (tlp-configuration
    (cpu-boost-on-ac? #t)
    (cpu-boost-on-bat? #t)
    (energy-perf-policy-on-ac "balance_performance")
    (energy-perf-policy-on-bat "balance_performance")
    (cpu-energy-perf-policy-on-bat "balance_performance")
    (pcie-aspm-on-ac "powersave")
    (pcie-aspm-on-bat "powersave")
    (wifi-pwr-on-ac? #f)
    (wifi-pwr-on-bat? #t)
    (sound-power-save-on-ac 1)
    (sound-power-save-on-bat 1)
    (nmi-watchdog? #f)
    (runtime-pm-on-ac "auto")
    (runtime-pm-on-bat "auto")
    (sata-linkpwr-on-ac "med_power_with_dipm")
    (sata-linkpwr-on-bat "med_power_with_dipm")))
```

Thermald was later removed: it is redundant with platform_profile and its
`--adaptive` mode double-throttled through RAPL against the Dell EC.

### 2a. Battery mode revision (2026-11-27)

The original battery profile (`cpu-boost-on-bat? #f`,
`energy-perf-policy-on-bat "power"`, `PLATFORM_PROFILE_ON_BAT=quiet`,
`pcie-aspm-on-bat "powersupersave"`) was reversed after measuring this
machine:

- `cpu-boost-on-bat? #f` sets `intel_pstate/no_turbo=1`, capping the i7-8565U
  at its 1.8 GHz base clock while the turbo ceiling is 4.6 GHz. A browser plus
  an agent session is not usable at that ceiling.
- `PLATFORM_PROFILE_ON_BAT=quiet` additionally lowers Dell EC PL1/PL2 and the
  fan, compounding the CPU cap.
- `energy-perf-policy-on-bat "power"` resolved to `balance_power`, below the
  AC setting, so HWP biased low on battery as well. Battery now sets both
  alias knobs to `balance_performance`, as AC already did.
- `pcie-aspm-on-bat "powersupersave"` measured as a power-only gain; the
  L1.1/L1.2 substates add return-from-L1 latency, so battery uses `powersave`.
- `vm.swappiness=150` with `vm.vfs_cache_pressure=200` swapped hot pages out
  and faulted them straight back (~10 of 15 GiB used, 6.4 GiB in swap), which
  was the visible stutter. Now 10 and 50.

Battery and AC now share turbo on, `balanced` platform profile and
`balance_performance` EPP. Idle remains cheap because HWP/EPP ramp frequency
down by itself; the aggressive battery settings were buying lost
responsiveness, not usable battery time.

### 3. Sysctl (already in system.scm)

No changes needed — existing vm.* tuning is appropriate.

## Revert Instructions

If issues arise after applying:

### PSR flicker (screen artifacts/flicker on lid open or after idle)
Add back to kernel-arguments: `"i915.enable_psr=0"`

### WiFi drops/instability after ASPM re-enable
Add to TLP config: `(pcie-aspm-on-ac "default") (pcie-aspm-on-bat "default")`
Or worst case, add back kernel arg: `"pcie_aspm=off"`

### Audio crackling/popping on wake from codec sleep
Set `(sound-power-save-on-bat 0)` in TLP config, or add kernel arg:
`"snd_hda_intel.power_save=0"`

## Expected Impact

- Responsiveness: battery now matches AC instead of running at the 1.8 GHz base
  clock under a quiet-mode PL1/PL2 cap; the earlier "quieter on battery"
  trade-off is dropped deliberately.
- Battery life: the original +30-60 min estimate came from ASPM + runtime PM +
  WiFi power save + audio sleep. Those remain, and swappiness 10 keeps more of
  the gain by not re-faulting swapped pages. Turbo on battery can spend some of
  it under sustained load; interactive workloads are the priority.
- Performance on AC: unchanged.
