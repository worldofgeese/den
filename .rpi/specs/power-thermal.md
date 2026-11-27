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
performance preference "balance_performance"
And platform profile is "balanced"
And HDA codec power-save is enabled on AC
And PCIe ASPM is "powersave" (not off, but not aggressive)

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
  balanced platform profile and balance_performance EPP are used on both AC
  and battery. Battery-only power tricks must not add interactive latency.
- WiFi stability takes priority over power saving — if QCA6174 drops, revert ASPM

## Out of Scope

- Custom fan curves (Dell XPS 13 doesn't expose fan PWM control)
- Undervolting (requires MSR writes, risky on locked firmware)
- Suspend/hibernate configuration (already handled by elogind)
- Display brightness automation (user preference)
