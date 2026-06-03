---
feature: power-thermal
status: accepted
design: .rpi/designs/2026-05-14-power-thermal-optimization.md
date: 2026-05-14
---

# Power & Thermal Management

## Scenarios

### Scenario: Fan noise reduced on battery
Given the laptop is on battery power
When the system has been idle for 30 seconds
Then the platform profile is set to "quiet" or "cool"
And CPU turbo boost is disabled
And fan speed is below 3000 RPM

### Scenario: PCIe devices enter low-power state on battery
Given the laptop is on battery power
When TLP applies battery policies
Then PCIe ASPM policy is "powersupersave"
And runtime PM is set to "auto" for all eligible devices

### Scenario: Audio codec sleeps when idle
Given no audio is playing
When 1 second of silence passes
Then the HDA Intel codec enters power-save mode
And no audible pop or crackle occurs on wake

### Scenario: Quiet sustainable charging on AC power
Given the laptop is on AC power (charging)
When idle or under light load
Then CPU turbo boost is disabled
And CPU frequency scaling governor is "powersave"
And HWP energy performance preference is "power"
And platform profile is "quiet"
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

### Scenario: Thermal throttling before fan ramp-up
Given thermald is running
When CPU temperature reaches 70°C
Then thermald reduces CPU frequency before BIOS fan curve triggers
And fan speed increase is delayed or avoided entirely

## Constraints

- TLP and power-profiles-daemon must not run simultaneously
- Kernel arguments must not disable ASPM or PSR (those are TLP's domain now)
- Aggressive power settings apply on battery; AC/charging defaults favor quiet thermals over peak performance
- WiFi stability takes priority over power saving — if QCA6174 drops, revert ASPM

## Out of Scope

- Custom fan curves (Dell XPS 13 doesn't expose fan PWM control)
- Undervolting (requires MSR writes, risky on locked firmware)
- Suspend/hibernate configuration (already handled by elogind)
- Display brightness automation (user preference)
