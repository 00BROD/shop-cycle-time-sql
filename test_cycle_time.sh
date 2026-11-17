#!/bin/bash
# Check cycle_time.sql against made-up cars with hand-checked answers.
#   ./test_cycle_time.sh            compare with cycle_time.expected.txt
#   ./test_cycle_time.sh --update   rewrite the expected file (then check the diff by hand)
#   ./test_cycle_time.sh --mutants  break the SQL on purpose, one way at a time; each broken
#                                   copy must FAIL, or the test is not watching that part
# Runs in a throwaway MariaDB container holding just the columns the SQL reads, so it never
# touches a real database and does not depend on which app version a stack has installed.
# Shortcut: the two tables are hand-declared here, not built by Frappe. Ceiling: a column
# renamed in the app is not noticed by this test. Upgrade: run it inside a bench test site.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" = "--mutants" ]; then
  # Each line: what the break is | a sed expression that makes it.
  mutants=(
    "demo/removed filter dropped from every ro block|s/WHERE COALESCE(o.plate, '') NOT LIKE 'DEMO%' AND COALESCE(o.removed, 0) = 0/WHERE 1/"
    "query 0b deleted|/^-- 0b\\./,/^ORDER BY visits DESC, retail_name;/d"
    "0b counts Stock cars as Retail again|/AND COALESCE(whose_car, '') <> 'Stock'/d"
    "aging edge 7/8 moved|s/BETWEEN 8 AND 14/BETWEEN 7 AND 14/"
    "aging edge 30/31 moved|s/days_in_shop > 30/days_in_shop >= 30/"
    # Dropping the idx tiebreak cannot be caught reliably: the engine may return tied rows in
    # the right order by luck. Reversing it can, so that is the break checked.
    "idx tiebreak reversed|s/l.at, l.idx/l.at, l.idx DESC/g"
    "backdated check-in ignored|s/LEAST(COALESCE(ro.checked_in_on, l.at), l.at)/l.at/"
    "bounced Ready counted as ready|s/AND (next_status IS NULL OR next_status = 'Picked Up')/AND 1/"
    "comebacks folded into the first visit|s/SUM(COALESCE(l.from_status = 'Picked Up', 0))/SUM(0)/"
    "time zone line dropped|/^SET time_zone/d"
  )
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  survived=0
  for m in "${mutants[@]}"; do
    what=${m%%|*}; expr=${m#*|}
    sed "$expr" "$here/cycle_time.sql" > "$tmp/m.sql"
    if cmp -s "$here/cycle_time.sql" "$tmp/m.sql"; then
      echo "BROKEN MUTANT (sed changed nothing): $what"; survived=1; continue
    fi
    if SQL="$tmp/m.sql" "$0" >/dev/null 2>&1; then
      echo "SURVIVED: $what"; survived=1
    else
      echo "caught:   $what"
    fi
  done
  [ $survived = 0 ] && echo "PASS: every deliberate break was caught"
  exit $survived
fi

cid=$(docker run -d --rm -e MARIADB_ROOT_PASSWORD=t -e MARIADB_DATABASE=t mariadb:11.8)
trap 'docker kill "$cid" >/dev/null' EXIT
# Ready = final server start with time zone tables loaded (the SQL sets a named time zone).
for _ in $(seq 60); do
  docker exec "$cid" mariadb -uroot -pt -h127.0.0.1 -N -e \
    "select count(*) > 0 from mysql.time_zone_name" 2>/dev/null | grep -q 1 && break
  sleep 1
done
run=(docker exec -i "$cid" mariadb -uroot -pt -h127.0.0.1 t -t)

got=$({
python3 - <<'EOF'
# The clock is pinned: NOW() is 2026-11-15 12:00 in the shop (20:00 UTC) on every run, so
# months, ISO weeks and "still waiting" hours never drift. SET timestamp fixes the instant;
# the SQL under test still has to set the shop's time zone itself, or every open stint
# comes out 8 hours long (the time zone mutant checks that).
print("SET timestamp = 1794772800;")
B = "TIMESTAMP'2026-10-01 08:00:00'"
h = lambda n: f"{B} + INTERVAL {n} HOUR"                          # fixed October history
d = lambda n: f"TIMESTAMP'2026-11-15 12:00:00' - INTERVAL {n} DAY"  # n days before shop-local now
print("""
CREATE TABLE `tabRepair Order` (name varchar(140) primary key, plate varchar(140),
  customer_name varchar(140), status varchar(140), tech_name varchar(140), whose_car varchar(140),
  removed int, checked_in_on datetime(6), creation datetime(6));
CREATE TABLE `tabRepair Order Status Log` (name varchar(140) primary key, parent varchar(140),
  idx int, at datetime(6), from_status varchar(140), to_status varchar(140));""")
# name, plate, customer, status, tech, whose_car, removed, checked in
cars = [
    ("RO-T1", "TEST001", "Test Person", "Picked Up", "Tech A", "Customer", 0, h(0)),
    ("RO-T2", "TEST002", "Example Auto Sales", "Waiting Parts", "Tech B", "Customer", 0, d(40)),  # open; dealer by name only
    ("RO-T3", "TEST003", "example automotive", "Picked Up", "Tech A", "Customer", 0, h(0)),   # never marked ready; a shop, not a dealer
    ("RO-T4", "TEST004", "EXAMPLE AUTO SALES ", "Picked Up", "Tech B", "Customer", 0, h(0)),  # bounced from ready, ready again
    ("RO-T5", "TEST005", "Comeback Person", "In Progress", "Tech A", "Customer", 0, d(50)),   # picked up, came back 2 days ago
    ("RO-T6", "TEST006", "Reopened Person", "Picked Up", "Tech A", "Customer", 0, h(0)),   # re-opened, then finished: 2nd visit timed
    ("RO-T7", "DEMO001", "Demo Customer A", "In Progress", "Tech A", "Customer", 0, d(90)),  # demo car: must not appear anywhere
    ("RO-T8", "TEST008", "Gone Person", "Diagnosing", "Tech A", "Customer", 1, d(20)),     # taken off the floor: must not appear
    ("RO-T9", "TEST009", "Lot Car", "Checked In", "Tech B", "Stock", 0, d(3)),             # dealer by the Stock flag, plain name
    # Demo and removed cars that touch EVERY query (ready, bounce, pickup, dealer-like name),
    # so a missing filter in any one query shows up.
    ("RO-T10", "DEMO002", "Demo Auto Sales", "Picked Up", "Tech A", "Customer", 0, h(0)),
    ("RO-T11", "TEST011", "Gone Auto Sales", "Picked Up", "Tech B", "Customer", 1, h(0)),
    ("RO-T12", "TEST012", "Test Person", "Picked Up", "Tech A", "Customer", 0, h(200)),   # repeat retail customer: 0b must list it
    ("RO-T13", "TEST013", "Lot Car", "Ready for Pickup", "Tech B", "Stock", 0, d(6)),    # repeat Stock car: 0b must NOT list it; ready, not picked up
    ("RO-T14", "TEST014", "Edge Seven", "Checked In", "Tech A", "Customer", 0, d(7)),     # aging bucket edges: 7 | 8 ... 30 | 31
    ("RO-T15", "TEST015", "Edge Eight", "Checked In", "Tech A", "Customer", 0, d(8)),
    ("RO-T16", "TEST016", "Edge Thirty", "Checked In", "Tech A", "Customer", 0, d(30)),
    ("RO-T17", "TEST017", "Edge Thirtyone", "Checked In", "Tech A", "Customer", 0, d(31)),
    ("RO-T18", "TEST018", "Tie Person", "Picked Up", "Tech A", "Customer", 0, h(300)),    # two log rows with the same `at`
    ("RO-T19", "TEST019", "Late Entry Person", "Picked Up", "Tech B", "Customer", 0, h(400)),  # arrival typed in 3 h before it was saved
    ("RO-T20", "TEST020", "Sent Back Person", "In Progress", "Tech A", "Customer", 0, d(4)),  # made ready, sent back to work: NOT ready
]
for c in cars:
    print("INSERT INTO `tabRepair Order` (name,plate,customer_name,status,tech_name,whose_car,removed,"
          f"checked_in_on,creation) VALUES ('{c[0]}','{c[1]}','{c[2]}','{c[3]}','{c[4]}','{c[5]}',{c[6]},{c[7]},NOW());")
bounce = lambda s: [(h(s), None, "Checked In"), (h(s + 2), "Checked In", "In Progress"),
                    (h(s + 5), "In Progress", "Ready for Pickup"), (h(s + 6), "Ready for Pickup", "In Progress"),
                    (h(s + 8), "In Progress", "Ready for Pickup"), (h(s + 9), "Ready for Pickup", "Picked Up")]
logs = {
    "RO-T1": [(h(0), None, "Checked In"), (h(2), "Checked In", "Diagnosing"),
              (h(26), "Diagnosing", "Waiting Parts"), (h(74), "Waiting Parts", "In Progress"),
              (h(80), "In Progress", "QC / Test Drive"), (h(81), "QC / Test Drive", "In Progress"),
              (h(84), "In Progress", "QC / Test Drive"), (h(86), "QC / Test Drive", "Ready for Pickup"),
              (h(110), "Ready for Pickup", "Picked Up")],
    "RO-T2": [(d(40), None, "Checked In"), (d(39), "Checked In", "Diagnosing"),
              (d(35), "Diagnosing", "Waiting Parts")],
    "RO-T3": [(h(0), None, "Checked In"), (h(10), "Checked In", "Picked Up")],
    "RO-T5": [(d(50), None, "Checked In"), (d(49), "Checked In", "Picked Up"),
              (d(2), "Picked Up", "In Progress")],
    "RO-T6": [(h(0), None, "Checked In"), (h(4), "Checked In", "Picked Up"),
              (h(100), "Picked Up", "In Progress"), (h(110), "In Progress", "Ready for Pickup"),
              (h(120), "Ready for Pickup", "Picked Up")],
    "RO-T8": [(d(20), None, "Checked In"), (d(19), "Checked In", "Diagnosing")],
    "RO-T9": [(d(3), None, "Checked In")],
    "RO-T7": [(d(90), None, "Checked In"), (d(89), "Checked In", "In Progress")],
    "RO-T4": [(h(0), None, "Checked In"), (h(5), "Checked In", "In Progress"),
              (h(10), "In Progress", "Ready for Pickup"), (h(12), "Ready for Pickup", "In Progress"),
              (h(15), "In Progress", "Ready for Pickup"), (h(20), "Ready for Pickup", "Picked Up")],
    "RO-T10": bounce(0),
    "RO-T11": bounce(0),
    "RO-T12": [(h(200), None, "Checked In"), (h(230), "Checked In", "Ready for Pickup"),
               (h(240), "Ready for Pickup", "Picked Up")],
    "RO-T13": [(d(6), None, "Checked In"), (d(5), "Checked In", "Ready for Pickup")],
    "RO-T14": [(d(7), None, "Checked In")],
    "RO-T15": [(d(8), None, "Checked In")],
    "RO-T16": [(d(30), None, "Checked In")],
    "RO-T17": [(d(31), None, "Checked In")],
    "RO-T18": [(h(300), None, "Checked In"), (h(305), "Checked In", "Diagnosing"),
               (h(305), "Diagnosing", "In Progress"), (h(308), "In Progress", "Ready for Pickup"),
               (h(309), "Ready for Pickup", "Picked Up")],
    "RO-T19": [(h(403), None, "Checked In"), (h(410), "Checked In", "Ready for Pickup"),
               (h(412), "Ready for Pickup", "Picked Up")],
    "RO-T20": [(d(4), None, "Checked In"), (d(3), "Checked In", "Ready for Pickup"),
               (d(2), "Ready for Pickup", "In Progress")],
}
for p, rows in logs.items():
    for i, (at, f, t) in enumerate(rows, 1):
        fs = "NULL" if f is None else f"'{f}'"
        # Frappe names child rows with random hashes, so primary-key order says nothing about
        # idx. Names run backwards here on purpose: only the SQL's own ORDER BY can fix it.
        print("INSERT INTO `tabRepair Order Status Log` (name,parent,idx,at,from_status,to_status) "
              f"VALUES ('{p}-L{99 - i}','{p}',{i},{at},{fs},'{t}');")
EOF
cat "${SQL:-$here/cycle_time.sql}"   # SQL=... runs a different copy (used by --mutants)
} | "${run[@]}")

if [ "${1:-}" = "--update" ]; then
  printf '%s\n' "$got" > "$here/cycle_time.expected.txt"; echo "expected file rewritten"; exit 0
fi
diff <(printf '%s\n' "$got") "$here/cycle_time.expected.txt" && echo "PASS: all queries match the hand-checked output"
