#!/bin/bash
# Check cycle_time.sql against nine made-up cars with hand-worked answers.
#   ./test_cycle_time.sh            compare with cycle_time.expected.txt
#   ./test_cycle_time.sh --update   rewrite the expected file (read the diff first)
# Runs in a throwaway MariaDB container holding just the columns the SQL reads, so it never
# touches a real database and does not depend on which app version a stack has installed.
# Shortcut: the two tables are hand-declared here, not built by Frappe. Ceiling: a column
# renamed in the app is not noticed by this test. Upgrade: run it inside a bench test site.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
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
B = "TIMESTAMP'2026-10-01 08:00:00'"
h = lambda n: f"{B} + INTERVAL {n} HOUR"
# Shop-local "n days ago", built from UTC so it does not depend on the session clock the
# SQL under test sets. If cycle_time.sql loses its SET time_zone line, hours come out 7-8 high.
d = lambda n: f"CONVERT_TZ(UTC_TIMESTAMP(),'UTC','America/Los_Angeles') - INTERVAL {n} DAY"
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
    ("RO-T6", "TEST006", "Reopened Person", "Picked Up", "Tech A", "Customer", 0, h(0)),   # re-opened, then finished
    ("RO-T7", "DEMO001", "Demo Customer A", "In Progress", "Tech A", "Customer", 0, d(90)),  # demo car: must not appear anywhere
    ("RO-T8", "TEST008", "Gone Person", "Diagnosing", "Tech A", "Customer", 1, d(20)),     # taken off the floor: must not appear
    ("RO-T9", "TEST009", "Lot Car", "Checked In", "Tech B", "Stock", 0, d(3)),             # dealer by the Stock flag, plain name
]
for c in cars:
    print("INSERT INTO `tabRepair Order` (name,plate,customer_name,status,tech_name,whose_car,removed,"
          f"checked_in_on,creation) VALUES ('{c[0]}','{c[1]}','{c[2]}','{c[3]}','{c[4]}','{c[5]}',{c[6]},{c[7]},NOW());")
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
}
for p, rows in logs.items():
    for i, (at, f, t) in enumerate(rows, 1):
        fs = "NULL" if f is None else f"'{f}'"
        print("INSERT INTO `tabRepair Order Status Log` (name,parent,idx,at,from_status,to_status) "
              f"VALUES ('{p}-L{i}','{p}',{i},{at},{fs},'{t}');")
EOF
cat "${SQL:-$here/cycle_time.sql}"   # SQL=... lets a deliberately broken copy prove the test can fail
} | "${run[@]}")

if [ "${1:-}" = "--update" ]; then
  printf '%s\n' "$got" > "$here/cycle_time.expected.txt"; echo "expected file rewritten"; exit 0
fi
diff <(printf '%s\n' "$got") "$here/cycle_time.expected.txt" && echo "PASS: all queries match the hand-worked answers"
