#!/bin/sh
# mmio-preload-remote.sh - the device half of au-slotA-mmiotrace.sh install-preload, staged to
# /tmp/mmio-preload.sh and run there.
#
# Arms the vendor's own debug hook so the next boot runs ar_lowdelay under the tracer: renders
# /usrdata/run_dbg.sh from the template the host pushed to /usrdata/run_dbg.sh.tmpl, then
# verifies and flushes it.
#
# This writes /usrdata on the STOCK slot, which is why every step is guarded. run.sh runs
# run_dbg.sh only when /usrdata/buildtime matches /usr/usrdata/buildtime, and on a MISMATCH it
# does `rm -rf /usrdata/*` and reboots. So buildtime is copied byte-exact and verified before
# run_dbg.sh is written, verified again after the sync, and any failure disarms the hook rather
# than leaving a half-installed one behind.
#
# The tracer window arrives as an environment variable set by the host at invocation, and is
# substituted into the template:
#   LO HI                the physical span to trap
#   READS TIME           also trap loads; add ns timestamps
#   NOMEM                skip /dev/mem trapping, capture only the ar_sys write ioctl
#   SKIP_LO SKIP_HI      leave one span untrapped inside a wide window
#   CENSUS               log unrecognised ar_sys ioctl request numbers
set -e

# 1. buildtime byte-exact FIRST, then verify - guards the rm -rf /usrdata/* wipe path.
cp /usr/usrdata/buildtime /usrdata/buildtime
o=$(md5sum /usr/usrdata/buildtime | cut -d" " -f1)
n=$(md5sum /usrdata/buildtime   | cut -d" " -f1)
if [ "$o" != "$n" ]; then
	echo "ABORT: buildtime mismatch ($o != $n) - NOT writing run_dbg.sh"
	rm -f /usrdata/run_dbg.sh /usrdata/run_dbg.sh.tmpl
	exit 1
fi
echo "buildtime match: $n"

# 2. resolve the REAL ar_lowdelay absolute path - abort if not found (a broken
#    shim with an empty target would recurse). Then substitute placeholders.
REAL=$(command -v ar_lowdelay 2>/dev/null || true)
if [ -z "$REAL" ]; then
	for d in /usr/bin /bin /usr/sbin /sbin /usr/usrdata; do
		[ -x "$d/ar_lowdelay" ] && REAL="$d/ar_lowdelay" && break
	done
fi

if [ -z "$REAL" ] || [ ! -x "$REAL" ]; then
	echo "ABORT: cannot locate real ar_lowdelay"
	rm -f /usrdata/run_dbg.sh.tmpl
	exit 1
fi
echo "real ar_lowdelay: $REAL"

sed -e "s#__REAL__#$REAL#g" -e "s#__LO__#$LO#g" -e "s#__HI__#$HI#g" \
	-e "s#__READS__#$READS#g" -e "s#__TIME__#$TIME#g" \
	-e "s#__NOMEM__#$NOMEM#g" \
	-e "s#__SKIP_LO__#$SKIP_LO#g" -e "s#__SKIP_HI__#$SKIP_HI#g" \
	-e "s#__CENSUS__#$CENSUS#g" \
	/usrdata/run_dbg.sh.tmpl > /usrdata/run_dbg.sh
rm -f /usrdata/run_dbg.sh.tmpl
chmod +x /usrdata/run_dbg.sh

# 3. sanity: no placeholders left, the shim env line is present, real path is executable.
if grep -q "__REAL__\|__LO__\|__HI__\|__READS__\|__TIME__\|__NOMEM__\|__SKIP_LO__\|__SKIP_HI__\|__CENSUS__" /usrdata/run_dbg.sh; then
	echo "ABORT: unsubstituted placeholder in run_dbg.sh"
	rm -f /usrdata/run_dbg.sh
	exit 1
fi

echo "--- shim LD_PRELOAD line (want mmiotrace.so + real path + window) ---"
grep -n "LD_PRELOAD=/usrdata/mmiotrace.so" /usrdata/run_dbg.sh
echo "--- self-remove + verbatim run.sh source present? (want both) ---"
grep -nE "rm -f /usrdata/run_dbg.sh|\. /usr/usrdata/run.sh" /usrdata/run_dbg.sh

# 4. FLUSH to flash before the operator can power-cut. /usrdata is ubifs;
#    without this the write cache can lose buildtime while run_dbg.sh persists,
#    which trips run.sh mismatch guard (rm -rf /usrdata/*; reboot) and scrubs the
#    hook. Sync, then re-verify the on-flash buildtime still matches by dropping
#    caches is not available, so cmp the two files after sync as the persistence
#    check the boot gate itself will do.
sync; sync

if ! cmp -s /usr/usrdata/buildtime /usrdata/buildtime; then
	echo "ABORT: buildtime mismatch AFTER sync - the gate would wipe the hook; not leaving it armed"
	rm -f /usrdata/run_dbg.sh; sync; exit 1
fi

echo "synced; buildtime persisted and still matches"
echo "--- staged ---"; ls -la /usrdata/run_dbg.sh /usrdata/buildtime /usrdata/mmiotrace.so
