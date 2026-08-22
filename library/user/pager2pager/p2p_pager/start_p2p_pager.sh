#!/bin/sh

echo "Service started" > /tmp/p2p_pager.log
echo "PATH=$PATH" >> /tmp/p2p_pager.log

# Probe common python locations first (absolute paths), then fall back to PATH lookups
PY=""
for p in /usr/bin/python3 /usr/bin/python /usr/local/bin/python3 /usr/local/bin/python /usr/bin/python3.11 /usr/bin/python3.10 /usr/bin/python3.9 /usr/bin/python3.8 /usr/bin/python2.7 /mmc/usr/bin/python3; do
	if [ -x "$p" ]; then
		PY="$p"
		break
	fi
done

if [ -z "$PY" ]; then
	if command -v python3 >/dev/null 2>&1; then
		PY=$(command -v python3)
	elif command -v python >/dev/null 2>&1; then
		PY=$(command -v python)
	fi
fi

if [ -z "$PY" ]; then
	echo "No python interpreter found on PATH or common locations" >> /tmp/p2p_pager.log
	exit 1
fi

echo "Using python: $PY" >> /tmp/p2p_pager.log
# Try to help the python binary find its shared libraries by adding common lib dirs
PYDIR=$(dirname "$PY")
for d in "$PYDIR/../lib" "$PYDIR/../lib64" /mmc/usr/lib /mmc/lib /usr/lib /lib; do
	if [ -d "$d" ]; then
		if [ -z "$LD_LIBRARY_PATH" ]; then
			LD_LIBRARY_PATH="$d"
		else
			LD_LIBRARY_PATH="$d:$LD_LIBRARY_PATH"
		fi
	fi
done
export LD_LIBRARY_PATH
echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH" >> /tmp/p2p_pager.log

exec "$PY" /usr/bin/p2p_pager >> /tmp/p2p_pager.log 2>&1
