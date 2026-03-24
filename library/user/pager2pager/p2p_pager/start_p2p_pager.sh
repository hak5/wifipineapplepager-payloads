#!/bin/sh

echo "Service started" > /tmp/p2p_pager.log
# Find a python interpreter (prefer python3)
PY=""
if command -v python3 >/dev/null 2>&1; then
	PY=$(command -v python3)
elif command -v python >/dev/null 2>&1; then
	PY=$(command -v python)
fi

if [ -z "$PY" ]; then
	echo "No python interpreter found on PATH" >> /tmp/p2p_pager.log
	exit 1
fi

exec "$PY" /usr/bin/p2p_pager >> /tmp/p2p_pager.log 2>&1
