# linux-rt

Ubuntu lowlatency kernel runtime profile for a dedicated RT core.

## What this does
- Reserves one CPU (optionally with SMT sibling) as RT target.
- Moves IRQ affinity to non-RT CPUs.
- Stops `irqbalance` while profile is active.
- Sets CPU governors to `performance`.
- Sets `kernel.sched_rt_runtime_us=-1` during profile.
- Restores previous settings with `revert`.

## Files
- `scripts/rt-core-profile.sh`: apply/revert/status runtime tuning.
- `scripts/run-cyclictest.sh`: run latency benchmark and save results.
- `scripts/benchmark-all.sh`: run baseline + profiled tests and generate report.
- `scripts/grub-rt-kargs.sh`: persist RT kernel args in GRUB (reboot required).
- `scripts/irq-map-advanced.sh`: advanced IRQ mapping by action regex.
- `scripts/plot-history.py`: generate SVG trend graph from benchmark history CSV.
- `scripts/rtos-like-profile.sh`: aggressive runtime RT profile (single RT CPU island).
- `scripts/run-rtos-like-validation.sh`: stress + cyclictest validation for RTOS-like profile.

## Quick start
```bash
cd linux-rt
chmod +x scripts/*.sh

# Show current status (no changes)
./scripts/rt-core-profile.sh status --rt-cpu 15

# Apply profile
sudo ./scripts/rt-core-profile.sh apply --rt-cpu 15

# Run 30s latency test on RT cpu 15
./scripts/run-cyclictest.sh 30 15

# Run baseline vs profiled in one shot and create report
./scripts/benchmark-all.sh 30 15

# Generate SVG graph from history CSV
./scripts/plot-history.py

# Revert profile
sudo ./scripts/rt-core-profile.sh revert
```

## Advanced
```bash
# Show current GRUB/default cmdline and RT state
./scripts/grub-rt-kargs.sh status

# Persist RT boot args (reboot required)
sudo ./scripts/grub-rt-kargs.sh apply --rt-cpus 15

# Revert GRUB boot args to backup
sudo ./scripts/grub-rt-kargs.sh revert

# Preview IRQ map changes without applying
./scripts/irq-map-advanced.sh show --rt-pattern 'eth|enp|igc|ptp'
sudo ./scripts/irq-map-advanced.sh apply --rt-cpus 15 --rt-pattern 'eth|enp|igc|ptp' --dry-run

# Apply IRQ map and later restore
sudo ./scripts/irq-map-advanced.sh apply --rt-cpus 15 --rt-pattern 'eth|enp|igc|ptp'
sudo ./scripts/irq-map-advanced.sh restore
```

## RTOS-Like Runtime Mode
```bash
# Check current runtime knobs
./scripts/rtos-like-profile.sh status --rt-cpu 15

# Apply aggressive runtime profile
sudo ./scripts/rtos-like-profile.sh apply --rt-cpu 15

# Validate under heavy non-RT load
./scripts/run-rtos-like-validation.sh 30 15

# Revert runtime profile
sudo ./scripts/rtos-like-profile.sh revert
```

## Notes
- `rt-core-profile.sh` is runtime-only tuning (no reboot).
- `grub-rt-kargs.sh` is persistent boot-time tuning (reboot required).
- Recommended kernel: Ubuntu `lowlatency`.
- If RT workload and noise still interfere, isolate more than one core.
