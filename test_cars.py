#!/usr/bin/env python3
"""The made-up cars for test_cycle_time.sh, and a second opinion on the answers.

  test_cars.py --sql            print the SQL that loads the cars into an empty database
  test_cars.py --check FILE     work every answer out again in plain Python, straight from
                                the cars below, and compare with the tables in FILE

The second opinion matters because the expected file is written from the SQL's own output.
This file shares no code with cycle_time.sql, so the two have to agree by being right.
Shortcut: it restates the rules (dealer words, stage ladder) instead of reading them from
the SQL. Ceiling: change a rule there and it must be changed here too, or the check fails.
"""
import re
import sys
from collections import defaultdict
from datetime import datetime, timedelta

# The test pins the database clock to NOW (shop-local; 20:00 UTC). See test_cycle_time.sh.
NOW = datetime(2026, 11, 15, 12)
NOW_EPOCH = 1794772800
BASE = datetime(2026, 10, 1, 8)
h = lambda n: BASE + timedelta(hours=n)   # fixed October history
d = lambda n: NOW - timedelta(days=n)     # n days before now (negative = in the future)

READY, PICKED = "Ready for Pickup", "Picked Up"
LADDER = ["Checked In", "Diagnosing", "Waiting Approval", "Waiting Parts",
          "In Progress", "QC / Test Drive", READY, PICKED]
DEALER_RE = "AUTO SALES|AUTO GROUP|CAR SALES|DEALER|WHOLESALE|AUTO MART|MOTOR CARS|AUTO BROKER"


def bounce(s):
    return [(h(s), None, "Checked In"), (h(s + 2), "Checked In", "In Progress"),
            (h(s + 5), "In Progress", READY), (h(s + 6), READY, "In Progress"),
            (h(s + 8), "In Progress", READY), (h(s + 9), READY, PICKED)]


# name, plate, customer, status, tech, whose_car, removed, parked, checked in, log rows
CARS = [
    ("RO-T1", "TEST001", "Test Person", PICKED, "Tech A", "Customer", 0, 0, h(0),
     [(h(0), None, "Checked In"), (h(2), "Checked In", "Diagnosing"),
      (h(26), "Diagnosing", "Waiting Parts"), (h(74), "Waiting Parts", "In Progress"),
      (h(80), "In Progress", "QC / Test Drive"), (h(81), "QC / Test Drive", "In Progress"),
      (h(84), "In Progress", "QC / Test Drive"), (h(86), "QC / Test Drive", READY),
      (h(110), READY, PICKED)]),
    # open; dealer by name only
    ("RO-T2", "TEST002", "Example Auto Sales", "Waiting Parts", "Tech B", "Customer", 0, 0, d(40),
     [(d(40), None, "Checked In"), (d(39), "Checked In", "Diagnosing"),
      (d(35), "Diagnosing", "Waiting Parts")]),
    # never made ready; a repair shop, not a dealer
    ("RO-T3", "TEST003", "example automotive", PICKED, "Tech A", "Customer", 0, 0, h(0),
     [(h(0), None, "Checked In"), (h(10), "Checked In", PICKED)]),
    # bounced from ready, ready again
    ("RO-T4", "TEST004", "EXAMPLE AUTO SALES ", PICKED, "Tech B", "Customer", 0, 0, h(0),
     [(h(0), None, "Checked In"), (h(5), "Checked In", "In Progress"),
      (h(10), "In Progress", READY), (h(12), READY, "In Progress"),
      (h(15), "In Progress", READY), (h(20), READY, PICKED)]),
    # picked up, came back for work 2 days ago
    ("RO-T5", "TEST005", "Comeback Person", "In Progress", "Tech A", "Customer", 0, 0, d(50),
     [(d(50), None, "Checked In"), (d(49), "Checked In", PICKED), (d(2), PICKED, "In Progress")]),
    # came back for work, then finished: the second visit is timed
    ("RO-T6", "TEST006", "Reopened Person", PICKED, "Tech A", "Customer", 0, 0, h(0),
     [(h(0), None, "Checked In"), (h(4), "Checked In", PICKED), (h(100), PICKED, "In Progress"),
      (h(110), "In Progress", READY), (h(120), READY, PICKED)]),
    # demo car: must not appear anywhere
    ("RO-T7", "DEMO001", "Demo Customer A", "In Progress", "Tech A", "Customer", 0, 0, d(90),
     [(d(90), None, "Checked In"), (d(89), "Checked In", "In Progress")]),
    # taken off the floor: must not appear
    ("RO-T8", "TEST008", "Gone Person", "Diagnosing", "Tech A", "Customer", 1, 0, d(20),
     [(d(20), None, "Checked In"), (d(19), "Checked In", "Diagnosing")]),
    # dealer by the Stock flag, plain name
    ("RO-T9", "TEST009", "Lot Car", "Checked In", "Tech B", "Stock", 0, 0, d(3),
     [(d(3), None, "Checked In")]),
    # Demo and removed cars that touch EVERY query (ready, bounce, pickup, dealer-like name),
    # so a missing filter in any one query shows up.
    ("RO-T10", "DEMO002", "Demo Auto Sales", PICKED, "Tech A", "Customer", 0, 0, h(0), bounce(0)),
    ("RO-T11", "TEST011", "Gone Auto Sales", PICKED, "Tech B", "Customer", 1, 0, h(0), bounce(0)),
    # repeat retail customer: 0b must list it. No tech assigned.
    ("RO-T12", "TEST012", "Test Person", PICKED, "", "Customer", 0, 0, h(200),
     [(h(200), None, "Checked In"), (h(230), "Checked In", READY), (h(240), READY, PICKED)]),
    # repeat Stock car: 0b must NOT list it. Ready, not picked up yet.
    ("RO-T13", "TEST013", "Lot Car", READY, "Tech B", "Stock", 0, 0, d(6),
     [(d(6), None, "Checked In"), (d(5), "Checked In", READY)]),
    # Aging bucket edges: 7 | 8 ... 14 | 15 ... 30 | 31. Two have no customer name (the app
    # only requires a plate or a VIN): 0b must not pool them into one repeat customer.
    ("RO-T14", "TEST014", "", "Checked In", "Tech A", "Customer", 0, 0, d(7), [(d(7), None, "Checked In")]),
    ("RO-T15", "TEST015", "", "Checked In", "Tech A", "Customer", 0, 0, d(8), [(d(8), None, "Checked In")]),
    ("RO-T16", "TEST016", "Edge Thirty", "Checked In", "Tech A", "Customer", 0, 0, d(30), [(d(30), None, "Checked In")]),
    ("RO-T17", "TEST017", "Edge Thirtyone", "Checked In", "Tech A", "Customer", 0, 0, d(31), [(d(31), None, "Checked In")]),
    # two status changes stamped at the same instant: only idx says which came first
    ("RO-T18", "TEST018", "Tie Person", PICKED, "Tech A", "Customer", 0, 0, h(300),
     [(h(300), None, "Checked In"), (h(305), "Checked In", "Diagnosing"),
      (h(305), "Diagnosing", "In Progress"), (h(308), "In Progress", READY), (h(309), READY, PICKED)]),
    # arrival typed in as two days before the car was saved in the app
    ("RO-T19", "TEST019", "Late Entry Person", PICKED, "Tech B", "Customer", 0, 0, h(400),
     [(h(448), None, "Checked In"), (h(454), "Checked In", READY), (h(456), READY, PICKED)]),
    # made ready, sent back to work, still there: NOT ready
    ("RO-T20", "TEST020", "Sent Back Person", "In Progress", "Tech A", "Customer", 0, 0, d(4),
     [(d(4), None, "Checked In"), (d(3), "Checked In", READY), (d(2), READY, "In Progress")]),
    # check-in date typed 5 days in the future: counts as 0 days, as on the shop's board
    ("RO-T21", "TEST021", "Typo Date Person", "Checked In", "Tech A", "Customer", 0, 0, d(-5),
     [(d(1), None, "Checked In")]),
    ("RO-T22", "TEST022", "Edge Fourteen", "Checked In", "Tech A", "Customer", 0, 0, d(14), [(d(14), None, "Checked In")]),
    ("RO-T23", "TEST023", "Edge Fifteen", "Checked In", "Tech A", "Customer", 0, 0, d(15), [(d(15), None, "Checked In")]),
    # pickup tapped by mistake and undone straight back to Ready, picked up for real later:
    # one visit, ready since the first Ready, one pickup
    ("RO-T24", "TEST024", "Oops Person", PICKED, "Tech A", "Customer", 0, 0, h(500),
     [(h(500), None, "Checked In"), (h(510), "Checked In", READY), (h(511), READY, PICKED),
      (h(512), PICKED, READY), (h(526), READY, PICKED)]),
    # same mis-tap, car still waiting: not picked up, and not a comeback (aged from check-in)
    ("RO-T25", "TEST025", "Oops Waiting Person", READY, "Tech A", "Customer", 0, 0, d(10),
     [(d(10), None, "Checked In"), (d(9), "Checked In", READY), (d(8), READY, PICKED),
      (d(7), PICKED, READY)]),
    # a customer car someone marked Parked On Purpose
    ("RO-T26", "TEST026", "Parked Person", "Waiting Approval", "Tech B", "Customer", 0, 1, d(45),
     [(d(45), None, "Checked In"), (d(44), "Checked In", "Waiting Approval")]),
]


def emit_sql():
    q = lambda v: "NULL" if v is None else "'" + str(v) + "'"
    # Same column types and collation Frappe gives these tables on a real site.
    print(f"""SET timestamp = {NOW_EPOCH};
CREATE TABLE `tabRepair Order` (name varchar(140) primary key, plate varchar(140),
  customer_name varchar(140), status varchar(140), tech_name varchar(140), whose_car varchar(140),
  removed int, parked int, checked_in_on datetime(6), creation datetime(6))
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE TABLE `tabRepair Order Status Log` (name varchar(140) primary key, parent varchar(140),
  idx int, at datetime(6), from_status varchar(140), to_status varchar(140))
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;""")
    for name, plate, cust, status, tech, whose, removed, parked, cin, log in CARS:
        print("INSERT INTO `tabRepair Order` (name,plate,customer_name,status,tech_name,whose_car,"
              "removed,parked,checked_in_on,creation) VALUES "
              f"({q(name)},{q(plate)},{q(cust)},{q(status)},{q(tech)},{q(whose)},{removed},{parked},{q(cin)},NOW());")
        for i, (at, frm, to) in enumerate(log, 1):
            # Frappe names child rows with random hashes, so primary-key order says nothing
            # about idx. Names run backwards here on purpose: only the SQL's ORDER BY fixes it.
            print("INSERT INTO `tabRepair Order Status Log` (name,parent,idx,at,from_status,to_status) "
                  f"VALUES ('{name}-L{99 - i}','{name}',{i},{q(at)},{q(frm)},{q(to)});")


# ---- the second opinion --------------------------------------------------------------------

def pct(vals, p):
    s = sorted(vals)
    k = (len(s) - 1) * p
    lo = int(k)
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


avg = lambda v: sum(v) / len(v)
hours = lambda a, b: (b - a).total_seconds() / 3600
is_dealer_name = lambda c: bool(re.search(DEALER_RE, c[2].upper()))
segment = lambda c: "Dealer" if c[5] == "Stock" or is_dealer_name(c) else "Retail"
FLOOR = [c for c in CARS if not c[1].startswith("DEMO") and not c[6]]   # demo and removed cars out


def visits(car):
    """Split a car's log into visits: (visit number, started, ready, picked)."""
    cin, log = car[8], car[9]
    groups = [[]]
    for row in log:
        if row[1] == PICKED and row[2] != READY and groups[-1]:
            groups.append([])
        groups[-1].append(row)
    out = []
    for n, rows in enumerate(groups):
        started = min(cin, rows[0][0]) if n == 0 else rows[0][0]
        work = [i for i, r in enumerate(rows) if r[2] not in (READY, PICKED)]
        after = rows[work[-1] + 1:] if work else rows
        ready = next((r[0] for r in after if r[2] == READY), None)
        picked = rows[-1][0] if rows[-1][2] == PICKED else None
        out.append((n, started, ready, picked))
    return out


def reference():
    t = {}

    names = defaultdict(int)
    for c in FLOOR:
        if is_dealer_name(c):
            names[c[2].strip().upper()] += 1
    t["dealer_name"] = [(k, v) for k, v in names.items()]

    names = defaultdict(int)
    for c in FLOOR:
        if not is_dealer_name(c) and c[5] != "Stock" and c[2].strip():
            names[c[2].strip().upper()] += 1
    t["retail_name"] = [(k, v) for k, v in names.items() if v >= 2]

    rows = []
    for seg in ("Retail", "Dealer"):
        cs = [c for c in FLOOR if segment(c) == seg]
        rows.append((seg, len(cs), sum(c[5] == "Stock" for c in cs), sum(is_dealer_name(c) for c in cs)))
    t["segment,cars"] = rows

    stints = defaultdict(list)   # (segment, stage) -> [(hours, still open)]
    for c in FLOOR:
        log = c[9]
        for i, (at, frm, to) in enumerate(log):
            if to == PICKED:
                continue
            entered = min(c[8], at) if i == 0 else at
            last = i == len(log) - 1
            stints[(segment(c), to)].append((hours(entered, NOW if last else log[i + 1][0]), last))
    t["segment,stage,stints"] = [
        (seg, stage, len(v), sum(o for _, o in v), avg([x for x, _ in v]), pct([x for x, _ in v], .5),
         pct([x for x, _ in v], .9), sum(x for x, _ in v)) for (seg, stage), v in stints.items()]

    made, left = defaultdict(list), defaultdict(list)
    for c in FLOOR:
        for n, started, ready, picked in visits(c):
            if ready:
                made[(ready.strftime("%Y-%m"), segment(c))].append((hours(started, ready) / 24, n, picked))
            if picked:
                left[(picked.strftime("%Y-%m"), segment(c))].append((hours(ready, picked) / 24 if ready else None, n))
    t["ready_month"] = [
        (m, seg, len(v), sum(n > 0 for _, n, _ in v), sum(p is None for _, _, p in v),
         avg([x for x, _, _ in v]), pct([x for x, _, _ in v], .5), pct([x for x, _, _ in v], .9))
        for (m, seg), v in made.items()]
    rows = []
    for (m, seg), v in left.items():
        timed = [x for x, _ in v if x is not None]
        rows.append((m, seg, len(v), len(timed), avg(timed) if timed else None,
                     pct(timed, .5) if timed else None, pct(timed, .9) if timed else None,
                     len(v) - len(timed), sum(n > 0 for _, n in v)))
    t["pickup_month"] = rows

    lot = defaultdict(list)
    for c in FLOOR:
        if c[3] == PICKED:
            continue
        returns = [at for at, frm, to in c[9] if frm == PICKED and to != READY]
        age = max(0, (NOW - (max(returns) if returns else c[8])).days)
        lot[(segment(c), c[3])].append((age, (NOW - c[9][-1][0]).days, c[7]))
    t["segment,stage,cars"] = [
        (seg, stage, len(v), sum(a <= 7 for a, _, _ in v), sum(8 <= a <= 14 for a, _, _ in v),
         sum(15 <= a <= 30 for a, _, _ in v), sum(a > 30 for a, _, _ in v), sum(p for _, _, p in v),
         avg([s for _, s, _ in v]), max(s for _, s, _ in v)) for (seg, stage), v in lot.items()]

    weeks = defaultdict(lambda: {"Retail": set(), "Dealer": set()})
    for c in FLOOR:
        for at, frm, to in c[9]:
            if to == READY:
                y, w, _ = at.isocalendar()
                weeks[(y * 100 + w, c[4] or "(unassigned)")][segment(c)].add(c[0])
    t["iso_week"] = [(wk, tech, len(v["Retail"]), len(v["Dealer"]), len(v["Retail"] | v["Dealer"]))
                     for (wk, tech), v in weeks.items()]

    back = defaultdict(list)
    for c in FLOOR:
        for at, frm, to in c[9]:
            if frm in LADDER and to in LADDER and LADDER.index(to) < LADDER.index(frm):
                back[(segment(c), frm, to)].append(c[0])
    t["segment,from_status"] = [(seg, frm, to, len(v), len(set(v))) for (seg, frm, to), v in back.items()]
    return t


# how many leading columns name a row in each table
KEYS = {"dealer_name": 1, "retail_name": 1, "segment,cars": 1, "segment,stage,stints": 2,
        "ready_month": 2, "pickup_month": 2, "segment,stage,cars": 2, "iso_week": 2,
        "segment,from_status": 3}


def read_tables(path):
    """The mariadb -t tables in a file: [(header cells, [row cells])]."""
    tables, lines = [], [l.rstrip("\n") for l in open(path)]
    cells = lambda l: [x.strip() for x in l.strip("|").split("|")]
    i = 0
    while i < len(lines):
        header = cells(lines[i + 1])
        i += 3
        rows = []
        while not lines[i].startswith("+"):
            rows.append(cells(lines[i]))
            i += 1
        tables.append((header, rows))
        i += 1
    return tables


def check(path):
    ref, bad, seen = reference(), [], set()
    for header, rows in read_tables(path):
        key = next((k for k in ref if ",".join(header).startswith(k)), None)
        if key is None:
            bad.append(f"no second opinion for the table starting {header[:3]}")
            continue
        seen.add(key)
        text = range(KEYS[key])
        want = {tuple(str(r[i]) for i in text): r for r in ref[key]}
        got = {tuple(r[i] for i in text): r for r in rows}
        for k in sorted(set(want) | set(got)):
            if k not in got or k not in want:
                bad.append(f"{key}: row {k} is only in the {'second opinion' if k in want else 'file'}")
                continue
            for i, hname in enumerate(header):
                if i in text:
                    continue
                g, w = got[k][i], want[k][i]
                if g == "NULL" or w is None:
                    ok = g == "NULL" and w is None
                else:
                    # the file is rounded; allow exactly the rounding, nothing more
                    slack = 0.5 if hname == "total_car_hrs" else 0.0500001 if "." in g else 0
                    ok = abs(float(g) - w) <= slack
                if not ok:
                    bad.append(f"{key} {k} {hname}: file says {g}, second opinion says {w}")
    bad += [f"{k}: the file has no such table" for k in ref if k not in seen and ref[k]]
    for b in bad:
        print("MISMATCH", b)
    return not bad


if __name__ == "__main__":
    if sys.argv[1:2] == ["--sql"]:
        emit_sql()
    elif sys.argv[1:2] == ["--check"] and len(sys.argv) == 3:
        sys.exit(0 if check(sys.argv[2]) else 1)
    else:
        sys.exit(__doc__)
