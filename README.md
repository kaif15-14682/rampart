# Rampart

[![CI](https://github.com/kaif15-14682/rampart/actions/workflows/ci.yml/badge.svg)](https://github.com/kaif15-14682/rampart/actions/workflows/ci.yml)

Checked, exactly-once intake for a folder of CSV files, in one Bash script.

Files land in an inbox: claim exports, visit lists, payment files. Rampart checks each one against the schema for its feed, then loads it into SQLite in a single transaction, or holds it in quarantine with a note saying exactly which row is wrong. A ledger of SHA-256 hashes means a file sent twice is never loaded twice, so every run is safe to repeat.

```
$ rampart run
claims_1127.csv          loaded   1,204 rows
claims_1127_resend.csv   skipped  already loaded as claims_1127.csv on 2026-11-27
remits_1127.csv          held     row 88: service_date '2026-02-30' is not a real date (YYYY-MM-DD)
visits_1127.csv          loaded   312 rows
4 files: 2 loaded (1,516 rows), 1 skipped, 1 held
```

## Why

Data drops are where bad data gets in. A clearinghouse resends yesterday's file, an export carries a date that doesn't exist, a column moves. Loading anyway means cleaning the database later. Rejecting quietly means someone finds out a week later. Rampart does neither: good files go in whole, bad files wait with a reason, and nothing goes in twice.

## What it does

- **Checks every row** against a plain-text schema: whole numbers, decimals, real calendar dates (29 February only in leap years), codes that must match a pattern, values from a fixed list, and required fields.
- **Loads a file whole or not at all.** The rows, the table and the ledger entry go in as one SQLite transaction.
- **Never loads the same content twice.** The ledger keeps each file's SHA-256, and a unique index makes the database itself refuse a second copy, whatever the file is called.
- **Holds bad files with a reason.** The file moves to quarantine next to a note listing the first 20 problems by row and column.
- **Waits for files that are still copying in.** Anything changed in the last few seconds is left for the next run.
- **Runs one at a time.** A lock folder (creating a folder is atomic) stops two runs overlapping, and a lock left by a killed run is cleared.
- **Archives** loaded files gzipped by day, and prunes them after the retention period.
- **Reports** what was loaded, held and skipped, and can post the report to a Slack or Teams webhook.
- **Reads real CSV**: quoted fields with commas and doubled quotes, Windows line endings, a UTF-8 byte order mark.

## Quick start

Needs bash 4.4 or newer, awk, sqlite3, gzip and sha256sum (or shasum). curl is only needed for posting reports.

```bash
git clone https://github.com/kaif15-14682/rampart.git
cd rampart
./examples/demo.sh      # runs the four sample files above in ./demo
make test               # 24 tests, needs bats
```

On your own feeds:

```bash
cp rampart.conf.example rampart.conf
./rampart init                          # creates inbox/, schemas/ and var/
cp examples/schemas/*.schema schemas/   # or write your own
./rampart run
```

## Schemas

One file per feed, `schemas/<feed>.schema`. A file named `claims_1127.csv` belongs to the `claims` feed. Each line is one column, in the CSV's order:

```
# name          type      required?  pattern, or allowed values separated by |
claim_id        int       required
patient_id      code      required   ^P[0-9][0-9][0-9][0-9][0-9][0-9]$
payer           enum      required   Medicare|Medicaid|Anthem BCBS|Healthfirst|NYCE PPO
billed          decimal   required
service_date    date      required
note            text      optional
```

| Type | Accepts |
| --- | --- |
| `int` | whole numbers |
| `decimal` | numbers, with or without a decimal point |
| `date` | real dates written YYYY-MM-DD |
| `text` | anything |
| `code` | values that match the pattern (an awk regular expression) |
| `enum` | one of the listed values |

Each feed gets a table with the same name: the schema's columns, plus `_file` and `_loaded_at`. Empty optional fields are stored as NULL.

## Commands

| Command | What it does |
| --- | --- |
| `rampart run` | check and load everything waiting in the inbox |
| `rampart watch --interval 60` | run every 60 seconds until stopped |
| `rampart report --since 2026-11-01` | files loaded, held and skipped since that day; `--post` also sends it to the webhook |
| `rampart prune --days 30` | delete archive days older than 30 days |
| `rampart doctor` | check the tools, folders and schemas |
| `rampart init` | create the folders and the database |

`--dry-run` shows what `run` or `prune` would do without changing anything. `--quiet` prints only warnings, which suits cron.

### On a schedule

```cron
*/15 * * * *  cd /srv/intake && /usr/local/bin/rampart --quiet run
0 7 * * *     cd /srv/intake && /usr/local/bin/rampart --quiet report --post
0 3 * * 0     cd /srv/intake && /usr/local/bin/rampart --quiet prune
```

With `--quiet`, cron only sends mail when a file is held or something fails.

### Exit status

| Status | Meaning |
| --- | --- |
| 0 | all good |
| 1 | usage or setup problem |
| 2 | at least one file was held |
| 3 | another run has the lock |
| 4 | a required tool is missing |

## Folder layout

```
inbox/                     files arrive here
schemas/claims.schema      one per feed
var/rampart.db             SQLite: one table per feed, plus rampart_ledger
var/archive/2026-11-27/    loaded and skipped files, gzipped
var/quarantine/            held files, each with a .reason.txt
var/logs/rampart.log       every action, timestamped
```

## Design notes

- The checker is one awk program with two modes. The first pass reports problems. Only a file that passes gets a second pass, which writes its INSERT statements. Both passes read the CSV with the same parser, so the rows loaded are exactly the rows checked.
- The config file is parsed line by line and never `source`d, so a settings file cannot run code.
- The webhook URL is a secret, so it is never written to the log.
- The sample files in `examples/drop` are made by `examples/generate.sh` from a seeded random number generator. They contain no real patient data.

## Testing

`make test` runs the bats suite and `make lint` runs ShellCheck. CI runs both on Ubuntu and macOS on every push. Rampart was written on Windows and is tested there too, in Git Bash.

## Limits

- One row per line: quoted fields can hold commas and quotes, but not line breaks.
- Patterns with `{n}` counts need gawk or a recent mawk. The example schemas avoid them.
- macOS ships bash 3.2. Install a newer one with `brew install bash`.

## License

MIT
