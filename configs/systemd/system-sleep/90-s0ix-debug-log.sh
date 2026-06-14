#!/bin/bash
# Persistent suspend/resume diagnostics for the G14 s2idle wedge investigation.
# Runs on every sleep transition: arg1 = pre|post, arg2 = suspend|hibernate|...
# Writes to /var/log/suspend-s0ix.log (survives a wedge: if a `pre` has no matching
# `post`, the machine died in sleep; the `pre` snapshot is preserved on disk).
#
# Key signal: on `post`, Residency Time in s0ix_stats should be NONZERO. If it is
# still 0 after a resume, the platform never reached hardware s0ix -> a device
# blocked it (see amd_pmc_idlemask / wakeup_sources captured below).
LOG=/var/log/suspend-s0ix.log
phase="$1"; action="$2"
{
  echo "================ $(date '+%F %T')  phase=$phase action=$action ================"
  echo "--- /sys/power/suspend_stats (last_failed_*) ---"
  grep -H . /sys/power/suspend_stats/* 2>/dev/null
  echo "--- amd_pmc s0ix_stats ---"
  cat /sys/kernel/debug/amd_pmc/s0ix_stats 2>/dev/null
  echo "--- amd_pmc idlemask (nonzero bits = blocks to deeper idle) ---"
  cat /sys/kernel/debug/amd_pmc/amd_pmc_idlemask 2>/dev/null
  echo "--- wakeup_count ---"
  cat /sys/power/wakeup_count 2>/dev/null
  echo "--- enabled wakeup sources ---"
  grep -H enabled /sys/devices/**/power/wakeup 2>/dev/null | grep -v disabled | head -40
  echo "--- dGPU power_state ---"
  cat /sys/bus/pci/devices/0000:64:00.0/power_state 2>/dev/null
  echo
} >> "$LOG" 2>&1
