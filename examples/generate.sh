#!/usr/bin/env bash
#
# Writes the sample files in examples/drop. Every ID, code and amount comes from a seeded
# number generator, so the files are the same on every machine and hold no real patient data.
#
#   claims_1127.csv          1,204 claim lines
#   claims_1127_resend.csv   the same file sent a second time
#   visits_1127.csv          312 visits
#   remits_1127.csv          140 payments, one with a date that does not exist (row 88)

set -euo pipefail

out=$(cd -- "$(dirname -- "$0")" && pwd)/drop
mkdir -p -- "$out"

LC_ALL=C awk -v out="$out" '
	# Park-Miller generator: exact in double precision, so every awk gives the same numbers
	function rnd() { seed = (seed * 16807) % 2147483647; return seed / 2147483647 }
	function pick(list,    a, n) { n = split(list, a, "|"); return a[int(rnd() * n) + 1] }
	function patient() { return sprintf("P%06d", 100000 + int(rnd() * 800000)) }
	function nov(d) { return sprintf("2026-11-%02d", d) }
	BEGIN {
		seed = 20418
		payers = "Medicare|Medicaid|Anthem BCBS|Healthfirst|NYCE PPO"
		ncpt = split("99213:95|99214:140|80053:42|85025:28|97110:65|72148:1180|70553:1460|73721:1120", cpt, "|")

		f = out "/claims_1127.csv"
		print "claim_id,patient_id,payer,cpt,icd10,billed,service_date" > f
		for (i = 1; i <= 1204; i++) {
			split(cpt[int(rnd() * ncpt) + 1], c, ":")
			printf "%d,%s,%s,%s,%s,%.2f,%s\n", 30000 + i, patient(), pick(payers), c[1],
				pick("J02.9|R50.9|M54.5|E11.9|I10|Z00.00|M25.561|R10.9"), c[2] * (0.9 + rnd() * 0.25), nov(1 + int(rnd() * 26)) > f
		}
		close(f)

		f = out "/visits_1127.csv"
		print "visit_id,patient_id,provider_npi,visit_date,visit_type" > f
		for (i = 1; i <= 312; i++)
			printf "%d,%s,1%09d,%s,%s\n", 50000 + i, patient(), int(rnd() * 999999999), nov(27), pick("new|follow-up|telehealth") > f
		close(f)

		f = out "/remits_1127.csv"
		print "claim_id,payer,paid,adjustment,carc,service_date,paid_date" > f
		for (i = 1; i <= 140; i++) {
			billed = 95 + rnd() * 1400; paid = billed * (0.55 + rnd() * 0.3); d = 1 + int(rnd() * 26)
			carc = rnd() < 0.7 ? "CO-45" : (rnd() < 0.5 ? "PR-2" : "")
			printf "%d,%s,%.2f,%.2f,%s,%s,2026-12-%02d\n", 30001 + int(rnd() * 1204), pick(payers), paid, billed - paid, carc,
				(i == 88 ? "2026-02-30" : nov(d)), d > f
		}
		close(f)
	}'

cp -- "$out/claims_1127.csv" "$out/claims_1127_resend.csv"
printf 'wrote %s\n' "$out"/*.csv
