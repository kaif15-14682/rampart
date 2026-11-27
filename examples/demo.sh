#!/usr/bin/env bash
#
# Runs Rampart end to end in a scratch folder on the sample files in examples/drop:
# two files load, one is a second copy of a file already loaded, one has a date that does not exist.
#
#   ./examples/demo.sh [folder]     (default: ./demo next to rampart)

set -euo pipefail

here=$(cd -- "$(dirname -- "$0")" && pwd)
root=${here%/*}
work=${1:-$root/demo}

# Only ever delete a folder this script made
if [[ -e $work && ! -e $work/.rampart-demo ]]; then
	printf 'demo: %s already exists and is not a demo folder; pass another path\n' "$work" >&2
	exit 1
fi
rm -rf -- "$work"
mkdir -p -- "$work/inbox"
: > "$work/.rampart-demo"
cp -R -- "$here/schemas" "$work/schemas"
printf 'inbox = inbox\ndata_dir = var\nschemas = schemas\nsettle_seconds = 0\n' > "$work/rampart.conf"
cp -- "$here"/drop/*.csv "$work/inbox/"

cd -- "$work"
printf '$ rampart run\n'
status=0
"$root/rampart" run || status=$?
printf '\n$ echo $?\n%d\n\n$ rampart report\n' "$status"
"$root/rampart" report
printf '\n$ cat var/quarantine/remits_1127.csv.reason.txt\n'
cat var/quarantine/remits_1127.csv.reason.txt
