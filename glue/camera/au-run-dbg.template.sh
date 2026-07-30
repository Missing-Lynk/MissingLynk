#!/bin/sh
# Tracer boot-hook (self-removing, one boot).
#
# Interposes ONLY ar_lowdelay under LD_PRELOAD, then runs the LIVE
# /usr/usrdata/run.sh normal path VERBATIM. It never regenerates the boot script,
# so USB (usb_gadget_configfs.sh), RF (ar813x) and video come up exactly as stock.
# If any step here fails it still falls through to sourcing run.sh, so the unit
# always boots normally.
#
# Placeholders __REAL__ / __LO__ / __HI__ / __READS__ / __TIME__ / __NOMEM__ / __SKIP_LO__ / __SKIP_HI__ / __CENSUS__ are substituted at install time by
# au-slotA-mmiotrace.sh install-preload.
HOOKLOG=/usrdata/hook.log
{ echo "=== run_dbg $(date) ==="; } >> "$HOOKLOG" 2>/dev/null

# 1. ar_lowdelay PATH shim -> the REAL binary under LD_PRELOAD. The shim calls the
#    absolute real path so it can never recurse into itself even with /usrdata/bin
#    first on PATH. The shim is used no matter which branch run.sh takes (plain
#    `ar_lowdelay &` or `stdbuf -oL ar_lowdelay | tee`): the explicit env
#    LD_PRELOAD overrides any libstdbuf preload stdbuf sets.
mkdir -p /usrdata/bin 2>/dev/null
cat > /usrdata/bin/ar_lowdelay <<'SHIM' 2>/dev/null
#!/bin/sh
echo "ar_lowdelay hooked $(date)" >> /usrdata/hook.log 2>/dev/null
exec env LD_PRELOAD=/usrdata/mmiotrace.so MMIOTRACE_OUT=/tmp/mmio.log MMIOTRACE_LO=__LO__ MMIOTRACE_HI=__HI__ MMIOTRACE_READS=__READS__ MMIOTRACE_TIME=__TIME__ MMIOTRACE_NOMEM=__NOMEM__ MMIOTRACE_SKIP_LO=__SKIP_LO__ MMIOTRACE_SKIP_HI=__SKIP_HI__ MMIOTRACE_IOCTL_CENSUS=__CENSUS__ __REAL__ "$@"
SHIM
chmod +x /usrdata/bin/ar_lowdelay 2>/dev/null
PATH=/usrdata/bin:$PATH
export PATH

# 2. Remove ourselves so the sourced run.sh below takes the NORMAL path (its
#    recheck sees no run_dbg.sh and falls through). No recursion, and a single
#    power cycle is enough to return to pure stock.
rm -f /usrdata/run_dbg.sh 2>/dev/null

# 3. Run the live, verbatim normal boot in THIS process (source, so the PATH shim
#    applies to the ar_lowdelay it launches).
{ echo "sourcing /usr/usrdata/run.sh $(date)"; } >> "$HOOKLOG" 2>/dev/null
# shellcheck disable=SC1091  # a device-side path: this template only ever runs on the AU,
# where /usr/usrdata/run.sh is the vendor's own boot script. It does not exist on the host.
. /usr/usrdata/run.sh
