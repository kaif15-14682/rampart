#!/usr/bin/env bats
#
# Every test runs in a fresh folder: an empty inbox, the example schemas, and a config that
# does not make new files wait to settle.

setup() {
	ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
	unset RAMPART_WEBHOOK RAMPART_CONFIG
	cd "$BATS_TEST_TMPDIR"
	mkdir inbox
	cp -R "$ROOT/examples/schemas" schemas
	printf 'inbox = inbox\ndata_dir = var\nschemas = schemas\nsettle_seconds = 0\n' > rampart.conf
}

rampart() { "$ROOT/rampart" "$@"; }

db() { sqlite3 var/rampart.db "$1" | tr -d '\r'; }

row() { echo "${1:-1},P000101,Medicare,99213,J02.9,120.00,2026-11-02"; } # a valid claim line

claims() { # file name, then data rows: a claims file with the right header
	local name=$1
	shift
	{
		echo "claim_id,patient_id,payer,cpt,icd10,billed,service_date"
		printf '%s\n' "$@"
	} > "inbox/$name"
}

@test "prints its help" {
	run rampart --help
	[ "$status" -eq 0 ]
	[[ $output == *"usage: rampart"* ]]
}

@test "rejects an unknown command" {
	run rampart fly
	[ "$status" -eq 1 ]
	[[ $output == *"unknown command 'fly'"* ]]
}

@test "init creates the folders and the database" {
	rmdir inbox
	run rampart init
	[ "$status" -eq 0 ]
	[ -d inbox ] && [ -d var/archive ] && [ -d var/quarantine ] && [ -f var/rampart.db ]
}

@test "loads a valid file, archives it and records it in the ledger" {
	claims claims_a.csv "$(row 1)" "$(row 2)" "$(row 3)"
	run rampart run
	[ "$status" -eq 0 ]
	[[ $output == *"claims_a.csv"*"loaded"*"3 rows"* ]]
	[ "$(db 'SELECT COUNT(*) FROM claims;')" -eq 3 ]
	[ "$(db "SELECT status FROM rampart_ledger WHERE file = 'claims_a.csv';")" = loaded ]
	[ ! -e inbox/claims_a.csv ]
	[ -f "var/archive/$(date +%F)/claims_a.csv.gz" ]
}

@test "stores numbers as numbers and text as text" {
	claims claims_a.csv "$(row 7)"
	rampart run
	[ "$(db 'SELECT typeof(claim_id), typeof(billed), typeof(payer) FROM claims;')" = "integer|real|text" ]
}

@test "skips a file whose content was already loaded, whatever it is called" {
	claims claims_a.csv "$(row 1)"
	rampart run
	claims claims_b.csv "$(row 1)"
	run rampart run
	[ "$status" -eq 0 ]
	[[ $output == *"claims_b.csv"*"skipped"*"already loaded as claims_a.csv"* ]]
	[ "$(db 'SELECT COUNT(*) FROM claims;')" -eq 1 ]
}

@test "holds a file with an impossible date, writes why, and loads none of it" {
	claims claims_bad.csv "$(row 1)" "2,P000102,Medicare,99213,J02.9,95.00,2026-02-30" "$(row 3)"
	run rampart run
	[ "$status" -eq 2 ]
	[[ $output == *"held"*"row 2: service_date '2026-02-30' is not a real date"* ]]
	[ -f var/quarantine/claims_bad.csv ]
	grep -q "row 2: service_date" var/quarantine/claims_bad.csv.reason.txt
	[ "$(db "SELECT COUNT(*) FROM sqlite_master WHERE name = 'claims';")" -eq 0 ]
}

@test "accepts 29 February in a leap year" {
	claims claims_leap.csv "1,P000101,Medicare,99213,J02.9,120.00,2028-02-29"
	run rampart run
	[ "$status" -eq 0 ]
}

@test "lists every problem in the note, not just the first" {
	claims claims_x.csv \
		"1,,Medicare,99213,J02.9,120.00,2026-11-02" \
		"2,P000102,Aetna,99213,J02.9,95.00,2026-11-02" \
		"3,P000103,Medicare,9921,J02.9,95.00,2026-11-02"
	run rampart run
	[ "$status" -eq 2 ]
	[[ $output == *"row 1: patient_id is empty but required (and 2 more)"* ]]
	grep -q "row 2: payer 'Aetna' is not one of" var/quarantine/claims_x.csv.reason.txt
	grep -q "row 3: cpt '9921' does not match" var/quarantine/claims_x.csv.reason.txt
}

@test "holds a file whose header does not match the schema" {
	printf 'claim_id,patient,payer\n1,P000101,Medicare\n' > inbox/claims_h.csv
	run rampart run
	[ "$status" -eq 2 ]
	[[ $output == *"header reads 'claim_id,patient,payer'"* ]]
}

@test "holds a row with the wrong number of fields" {
	claims claims_f.csv "1,P000101,Medicare,99213"
	run rampart run
	[ "$status" -eq 2 ]
	[[ $output == *"row 1: has 4 fields, expected 7"* ]]
}

@test "holds a file for a feed with no schema" {
	printf 'id\n1\n' > inbox/orders_1.csv
	run rampart run
	[ "$status" -eq 2 ]
	[[ $output == *"no schema for the 'orders' feed"* ]]
}

@test "reads quoted fields with commas and doubled quotes, and empty fields as NULL" {
	printf 'id int required\nnote text optional\n' > schemas/notes.schema
	printf 'id,note\n1,"Smith, John said ""call back"""\n2,\n' > inbox/notes_1.csv
	run rampart run
	[ "$status" -eq 0 ]
	[ "$(db 'SELECT note FROM notes WHERE id = 1;')" = 'Smith, John said "call back"' ]
	[ "$(db 'SELECT note IS NULL FROM notes WHERE id = 2;')" -eq 1 ]
}

@test "accepts Windows line endings and a byte order mark" {
	printf '\357\273\277claim_id,patient_id,payer,cpt,icd10,billed,service_date\r\n%s\r\n' "$(row 1)" > inbox/claims_win.csv
	run rampart run
	[ "$status" -eq 0 ]
	[ "$(db 'SELECT COUNT(*) FROM claims;')" -eq 1 ]
}

@test "a dry run changes nothing" {
	claims claims_a.csv "$(row 1)"
	run rampart --dry-run run
	[ "$status" -eq 0 ]
	[[ $output == *"to load"* ]]
	[ -f inbox/claims_a.csv ]
	[ ! -e var ]
}

@test "leaves a file alone while it may still be arriving" {
	sed -i.bak 's/^settle_seconds.*/settle_seconds = 3600/' rampart.conf
	claims claims_a.csv "$(row 1)"
	run rampart run
	[ "$status" -eq 0 ]
	[[ $output == *"still arriving"* ]]
	[ -f inbox/claims_a.csv ]
}

@test "refuses to run while another run holds the lock" {
	mkdir -p var/.lock
	echo $$ > var/.lock/pid
	run rampart run
	[ "$status" -eq 3 ]
	[[ $output == *"another run is in progress"* ]]
}

@test "clears a lock left by a process that is gone" {
	mkdir -p var/.lock
	echo 999999 > var/.lock/pid
	claims claims_a.csv "$(row 1)"
	run rampart run
	[ "$status" -eq 0 ]
	[ ! -e var/.lock ]
}

@test "the report lists what was loaded, held and skipped" {
	claims claims_a.csv "$(row 1)"
	claims claims_b.csv "$(row 1)"
	claims claims_c.csv "1,P000101,Medicare,99213,J02.9,abc,2026-11-02"
	run rampart run
	run rampart report
	[ "$status" -eq 0 ]
	[[ $output == *"loaded"*"1 file, 1 row"* ]]
	[[ $output == *"held"*"claims_c.csv: row 1: billed 'abc' is not a number"* ]]
	[[ $output == *"skipped"*"claims_b.csv: already loaded as claims_a.csv"* ]]
}

@test "report --post needs a webhook" {
	claims claims_a.csv "$(row 1)"
	rampart run
	run rampart report --post
	[ "$status" -eq 1 ]
	[[ $output == *"no webhook"* ]]
}

@test "prune deletes archive days older than the retention period" {
	mkdir -p var/archive/2020-01-01 "var/archive/$(date +%F)"
	run rampart prune --days 30
	[ "$status" -eq 0 ]
	[ ! -e var/archive/2020-01-01 ]
	[ -d "var/archive/$(date +%F)" ]
}

@test "rejects an unknown setting in the config file" {
	echo 'colour = red' >> rampart.conf
	run rampart run
	[ "$status" -eq 1 ]
	[[ $output == *"unknown setting 'colour'"* ]]
}

@test "doctor passes on a working setup" {
	run rampart doctor
	[ "$status" -eq 0 ]
	[[ $output == *"all good"* ]]
}

@test "doctor catches a schema with a broken pattern" {
	printf 'id code required ^[0-9\n' > schemas/bad.schema
	run rampart doctor
	[ "$status" -eq 4 ]
	[[ $output == *"bad.schema"*"is not a valid pattern"* ]]
}
