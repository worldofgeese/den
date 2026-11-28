---
feature: power-thermal
status: accepted
design: .rpi/designs/2026-05-14-power-thermal-optimization.md
date: 2026-05-14
---

# Power & Thermal Management

## Scenarios

### Scenario: Battery mode stays responsive instead of quiet
Given the laptop is on battery power
When a browser and an agent session are running
Then CPU turbo boost is enabled
And the platform profile is "balanced"
And HWP energy performance preference is "balance_performance"
Because an i7-8565U pinned to its 1.8 GHz base clock stutters under this
workload, and quiet mode also cuts PL1/PL2 and the fan
And idle power stays low because HWP ramps the CPU down on its own

### Scenario: PCIe devices enter low-power state on battery
Given the laptop is on battery power
When TLP applies battery policies
Then PCIe ASPM policy is "powersave"
And runtime PM is set to "auto" for all eligible devices

Note: "powersupersave" (L1.1/L1.2 substates) measured only a power gain at
idle and adds NVMe return latency, so it is not used.

### Scenario: Audio codec sleeps when idle
Given no audio is playing
When 1 second of silence passes
Then the HDA Intel codec enters power-save mode
And no audible pop or crackle occurs on wake

### Scenario: Quiet sustainable charging on AC power
Given the laptop is on AC power (charging)
When idle or under light load
Then CPU turbo boost is enabled
And CPU frequency scaling governor is "powersave" with HWP energy
performance preference 64
Because EPP 64 cut the median of a bursty 50 ms task from about 44-57 ms to
about 22 ms for about 3 W more idle power (about 4 W to about 7 W);
"performance" idles at 12-17 W and runs hotter (measured 2026-11-28)
And platform profile is "balanced"
And HDA codec power-save is enabled on AC
And PCIe ASPM is "powersave" (not off, but not aggressive)

### Scenario: Sustained power limit stays at 20 W
Given Dell firmware caps the sustained package power (intel-rapl-mmio:0
constraint_0, long_term) at 15 W
When the system boots, resumes from S3, or AC is plugged or unplugged
Then constraint_0_power_limit_uw is 20000000
And the undervolt (core/cache -90 mV, GPU -50 mV) is applied again on resume
Because 20 W gave 31% more sustained throughput at 87C, and 25 W was
thermal-bound with no further gain (measured 2026-11-28)
And a missing powercap file is logged and skipped, never an error

### Scenario: AC charging capped to reduce heat and wear
Given the laptop is on AC power (charging)
When battery charge reaches 85%
Then charging stops until charge falls below 75%
And charging resumes only after charge drops below 75%

### Scenario: WiFi remains stable with ASPM enabled
Given PCIe ASPM is enabled (not "off")
When the QCA6174 WiFi adapter is actively connected
Then no connection drops occur over a 10-minute period
And latency remains below 50ms to the default gateway

### Scenario: Display panel self-refresh saves power
Given the display is showing static content
When i915 PSR is enabled
Then the display enters self-refresh mode
And no visible flicker or artifacts appear

### Scenario: Swapping does not stall the desktop
Given the laptop is on battery power
When more than half of RAM is in use
Then vm.swappiness is 10 and vm.vfs_cache_pressure is 50
And hot anonymous pages stay resident instead of being faulted back

## Constraints

- TLP and power-profiles-daemon must not run simultaneously
- Kernel arguments must not disable ASPM or PSR (those are TLP's domain now)
- Responsiveness takes priority over idle wattage on battery: turbo, the
  balanced platform profile and balance_performance EPP are used on battery,
  and EPP 64 on AC. Battery-only power tricks must not add interactive latency.
- The 20 W sustained limit and the undervolt arguments are defined once in
  guix/system.scm and shared by boot, resume and the AC udev rule
- WiFi stability takes priority over power saving — if QCA6174 drops, revert ASPM

## Out of Scope

- Custom fan curves (Dell XPS 13 doesn't expose fan PWM control)
- Suspend/hibernate configuration (already handled by elogind)
- Display brightness automation (user preference)
