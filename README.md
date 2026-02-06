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

# Revert profile
sudo ./scripts/rt-core-profile.sh revert
```

## Notes
- This is runtime-only tuning (no GRUB cmdline changes).
- Recommended kernel: Ubuntu `lowlatency`.
- If RT workload and noise still interfere, isolate more than one core.
