#!/bin/bash
# Check cycle_time.sql against the made-up cars in test_cars.py.
#   ./test_cycle_time.sh            run every query, compare with cycle_time.expected.txt,
#                                   then check that file against a second, SQL-free working
#   ./test_cycle_time.sh --update   rewrite the expected file (the second working must agree)
#   ./test_cycle_time.sh --mutants  break the SQL on purpose, one way at a time; each broken
#                                   copy must change the output, or the test is not watching
#   MARIADB=10.6 ./test_cycle_time.sh   run on another MariaDB version (default 11.8)
# Exit 0 = pass, 1 = wrong numbers, 3 = the test itself could not run (never a "pass" or a
# "caught").
# Runs in a throwaway MariaDB container holding just the columns the SQL reads, so it never
# touches a real database and does not depend on which app version a stack has installed.
# Shortcut: the two tables are hand-declared in test_cars.py, with the column types and
# collation Frappe gives them, not built by Frappe. Ceiling: a column renamed in the app is
# not noticed by this test. Upgrade: run it inside a bench test site.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
sql="$here/cycle_time.sql"
expected="$here/cycle_time.expected.txt"
image="mariadb:${MARIADB:-11.8}"
die() { echo "ERROR: $*" >&2; exit 3; }

cid=$(docker run -d --rm -e MARIADB_ROOT_PASSWORD=t "$image") || die "could not start $image"
trap 'docker kill "$cid" >/dev/null 2>&1' EXIT
# Ready = final server start with time zone tables loaded (the SQL sets a named time zone).
up=0
for _ in $(seq 90); do
  if docker exec "$cid" mariadb -uroot -pt -h127.0.0.1 -N -e \
      "select count(*) > 0 from mysql.time_zone_name" 2>/dev/null | grep -q 1; then up=1; break; fi
  sleep 1
done
[ $up = 1 ] || die "$image did not come up"

# run_sql FILE: a fresh database, the made-up cars, then FILE. Prints the result tables.
run_sql() {
  { echo "DROP DATABASE IF EXISTS t; CREATE DATABASE t; USE t;"
    python3 "$here/test_cars.py" --sql
    cat "$1"
  } | docker exec -i "$cid" mariadb -uroot -pt -h127.0.0.1 -t
}

got=$(run_sql "$sql") || die "cycle_time.sql did not run on $image"

case "${1:-}" in
--update)
  printf '%s\n' "$got" > "$expected"; echo "expected file rewritten"
  python3 "$here/test_cars.py" --check "$expected" || { echo "FAIL: the second working disagrees with the new file"; exit 1; }
  echo "the second working agrees with it"
  ;;
--mutants)
  [ "$got" = "$(cat "$expected")" ] || die "the unbroken SQL does not pass; fix that before trusting any mutant"
  # Each line: what the break is | a sed expression that makes it.
  mutants=(
    "demo/removed filter dropped from every ro block|s/WHERE COALESCE(o.plate, '') NOT LIKE 'DEMO%' AND COALESCE(o.removed, 0) = 0/WHERE 1/"
    "query 0b deleted|/^-- 0b\\./,/^ORDER BY visits DESC, retail_name;/d"
    "0b counts Stock cars as Retail again|/AND COALESCE(whose_car, '') <> 'Stock'/d"
    "0b pools cars with no name into one customer|/AND TRIM(COALESCE(customer_name, '')) <> ''/d"
    "aging edge 7/8 moved|s/BETWEEN 8 AND 14/BETWEEN 7 AND 14/"
    "aging edge 14/15 moved|s/BETWEEN 15 AND 30)/BETWEEN 16 AND 30)/"
    "aging edge 30/31 moved|s/days_in_shop > 30/days_in_shop >= 30/"
    "future check-in falls out of the aging buckets|s/GREATEST(0, TIMESTAMPDIFF(DAY, COALESCE(/(TIMESTAMPDIFF(DAY, COALESCE(/"
    "undone pickup resets a car's age|/^            AND l.to_status <> 'Ready for Pickup'),/s/AND l.to_status <> 'Ready for Pickup'//"
    "parked cars not counted|s/SUM(parked)/SUM(0)/"
    # Dropping the idx tiebreak cannot be caught reliably: the engine may return tied rows in
    # the right order by luck. Reversing it can, so that is the break checked.
    "idx tiebreak reversed|s/l.at, l.idx/l.at, l.idx DESC/g"
    "query 1 ignores a backdated check-in|s/IF(l.from_status IS NULL, LEAST(COALESCE(ro.checked_in_on, l.at), l.at), l.at)/l.at/"
    "query 1 trusts a check-in dated in the future|s/IF(l.from_status IS NULL, LEAST(COALESCE(ro.checked_in_on, l.at), l.at), l.at)/IF(l.from_status IS NULL, COALESCE(ro.checked_in_on, l.at), l.at)/"
    "query 2 ignores a backdated check-in|s/IF(visit = 0, LEAST(COALESCE(MAX(checked_in_on), MIN(at)), MIN(at)), MIN(at))/MIN(at)/"
    "a Ready that was sent back counts as ready|s/AND work_run = last_run/AND 1/"
    "comebacks folded into the first visit|s/SUM(COALESCE(l.from_status = 'Picked Up' AND l.to_status <> 'Ready for Pickup', 0))/SUM(0)/"
    "undone pickup counted as a comeback|s/SUM(COALESCE(l.from_status = 'Picked Up' AND l.to_status <> 'Ready for Pickup', 0))/SUM(COALESCE(l.from_status = 'Picked Up', 0))/"
    "undone pickup counted as a pickup|s/AND COALESCE(next_status, '') <> 'Ready for Pickup', at, NULL))/, at, NULL))/"
    "blank tech not labelled|s/COALESCE(NULLIF(ro.tech_name, ''), '(unassigned)')/ro.tech_name/"
    "time zone line dropped|/^SET time_zone/d"
  )
  tmp=$(mktemp -d); trap 'docker kill "$cid" >/dev/null 2>&1; rm -rf "$tmp"' EXIT
  bad=0
  for m in "${mutants[@]}"; do
    what=${m%%|*}; expr=${m#*|}
    sed "$expr" "$sql" > "$tmp/m.sql"
    if cmp -s "$sql" "$tmp/m.sql"; then
      echo "BROKEN MUTANT (sed changed nothing): $what"; bad=1
    elif ! out=$(run_sql "$tmp/m.sql" 2>"$tmp/err"); then
      # an error is not a catch: it says nothing about whether the test reads these numbers
      echo "BROKEN MUTANT (SQL did not run: $(head -c 120 "$tmp/err")): $what"; bad=1
    elif [ "$out" = "$got" ]; then
      echo "SURVIVED: $what"; bad=1
    else
      echo "caught:   $what"
    fi
  done
  [ $bad = 0 ] && echo "PASS: every deliberate break changed the output (${#mutants[@]} of ${#mutants[@]})"
  exit $bad
  ;;
*)
  diff <(printf '%s\n' "$got") "$expected" || { echo "FAIL: output differs from the expected file"; exit 1; }
  python3 "$here/test_cars.py" --check "$expected" || { echo "FAIL: the second working disagrees with the expected file"; exit 1; }
  echo "PASS: all queries match the expected file, and the second working agrees ($image)"
  ;;
esac
