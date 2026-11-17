# Shop cycle-time analysis in SQL

How long does a car sit in each stage of an auto repair shop, and where does the waiting time go?

This is the SQL I wrote to answer that for a repair shop's vehicle tracker, plus a test that runs every query on 26 made-up cars. The expected answers are worked out twice: once by the SQL, once by a separate Python file that shares no code with it.

**Status:** the numbers shown here come from the made-up test cars. The queries have not been run on the shop's production data yet, and no shop or customer data is in this repo. The table names, column names, column types and status names were checked against the tracker's own schema.

## The data

The tracker moves each car through eight stages:

Checked In > Diagnosing > Waiting Approval > Waiting Parts > In Progress > QC / Test Drive > Ready for Pickup > Picked Up

Two tables matter:

| Table | Grain | Used for |
|---|---|---|
| `tabRepair Order` | one row per car visit | current status, tech, check-in time, customer type |
| `tabRepair Order Status Log` | one row per stage change (append-only) | every timing in this analysis |

## What the queries answer

| # | Question | Technique |
|---|---|---|
| 0 | How were cars split into Dealer and Retail, and is the rule right? | rule check queries, one names-free |
| 1 | How long does a car spend in each stage? | `LEAD()` over the status log, median and p90 with `PERCENTILE_CONT` |
| 2a | How long from arrival to ready (the shop's speed), by month? | one row per visit, grouped by the month the car was made ready; median and p90 |
| 2b | How long from ready to pickup (the customer's speed), by month? | grouped by the month the car was picked up; median and p90 |
| 3 | How old are the cars on the lot right now? | aging buckets: 0-7, 8-14, 15-30, 31+ days, with a count of cars parked on purpose |
| 4 | How many cars reach Ready per week? | distinct cars per ISO week, per assigned tech |
| 5 | How often does a car move backward a stage? | stage positions compared with `FIELD()` |

## Decisions worth explaining

- **Timings come from the status log, not the "ready on" and "picked up on" columns.** The app stamps those columns once and never updates them, so they go stale when a car bounces back from Ready or is re-opened after pickup. An early version that used them could report a negative ready-to-pickup time.
- **Cars still sitting in a stage are counted, up to now.** Leaving them out would hide the worst waits. Each stage reports `open_now`, so a reader can see when an average is still growing.
- **Each monthly number is grouped by the month of the event that ends it.** Shop speed (arrival to ready) goes by the month the car was made ready, so a finished car counts even while it waits for its owner. Customer speed (ready to pickup) goes by the month it was picked up. Grouping by check-in month makes the newest month look fast, because its slow cars have not finished yet.
- **A comeback is its own visit.** A car that comes back for work after a pickup is timed from the day it came back, the same way the aging query counts it.
- **An undone pickup is not a comeback.** The app lets any status follow any other, so a pickup tapped by mistake gets undone straight back to Ready. That car never left: it stays one visit, with one pickup, ready since its first Ready.
- **Ready means the Ready that stuck.** A car sent back to work from Ready was not ready. Query 2 takes the first Ready after the visit's last work stage.
- **A check-in dated in the future counts as zero days,** the way the shop's own board treats it, so the aging buckets always add up to the number of cars.
- **A backdated check-in starts the clock.** The app stamps the first log row when the car is saved, so when someone types in an earlier arrival, queries 1 and 2 both use that arrival.
- **Gaps are counted, not dropped.** Cars picked up without being made ready are not timed but are reported in their own column.
- **Median and 90th percentile sit next to the average.** One car waiting five weeks on a part moves the average a long way.

## Known limits

- Hours are wall-clock: nights and weekends count.
- A no-show car counts as waiting until someone removes it or marks it picked up.
- The Dealer rule falls back on matching customer names for cars checked in before the "Stock" flag existed. It matches anywhere in the name, so a tire wholesaler would count as a dealer. Query 0 exists to check that rule. The flag is read as it is set today, not as it was at check-in.
- A pickup tapped by mistake and undone into a work stage (not back to Ready) still reads as a comeback. Query 5 lists every move out of Picked Up.
- Cars someone marked Parked On Purpose are still counted everywhere, as they are on the shop's board. Query 3 shows how many are in each row; query 1 does not separate them.
- The per-tech weekly count uses the tech assigned today, so it is not safe for ranking technicians. It also counts every arrival at Ready, including cars later sent back, so it can run higher than query 2a.
- A car made ready in one month and sent back to work the next drops out of the first month's 2a row. Read the newest month as provisional.

## Sample output (made-up cars)

Time in each stage, from the test data:

```
+---------+------------------+--------+----------+---------+------------+---------+---------------+
| segment | stage            | stints | open_now | avg_hrs | median_hrs | p90_hrs | total_car_hrs |
+---------+------------------+--------+----------+---------+------------+---------+---------------+
| Retail  | Checked In       |     18 |        7 |   153.1 |       24.0 |   468.0 |          2755 |
| Retail  | Diagnosing       |      2 |        0 |    12.0 |       12.0 |    21.6 |            24 |
| Retail  | Waiting Approval |      1 |        1 |  1056.0 |     1056.0 |  1056.0 |          1056 |
| Retail  | Waiting Parts    |      1 |        0 |    48.0 |       48.0 |    48.0 |            48 |
| Retail  | In Progress      |      6 |        2 |    19.7 |        8.0 |    48.0 |           118 |
| Retail  | QC / Test Drive  |      2 |        0 |     1.5 |        1.5 |     1.9 |             3 |
| Retail  | Ready for Pickup |     10 |        1 |    27.8 |       12.0 |    38.4 |           278 |
| Dealer  | Checked In       |      4 |        1 |    31.3 |       24.0 |    57.6 |           125 |
| Dealer  | Diagnosing       |      1 |        0 |    96.0 |       96.0 |    96.0 |            96 |
| Dealer  | Waiting Parts    |      1 |        1 |   840.0 |      840.0 |   840.0 |           840 |
| Dealer  | In Progress      |      2 |        0 |     4.0 |        4.0 |     4.8 |             8 |
| Dealer  | Ready for Pickup |      3 |        1 |    42.3 |        5.0 |    97.0 |           127 |
+---------+------------------+--------+----------+---------+------------+---------+---------------+
```

The full expected output for all queries is in `cycle_time.expected.txt`.

## Run the test

Needs Docker and Python 3. It starts a throwaway MariaDB container, pins the clock to a fixed moment, loads 26 made-up cars into tables with the column types and collation Frappe gives them, runs every query, and compares the output with the expected file. Then `test_cars.py` works every answer out again in plain Python and checks the expected file against that. It passes on MariaDB 10.6 and 11.8.

```
./test_cycle_time.sh                # compare with the expected file and the second working
./test_cycle_time.sh --mutants      # break the SQL twenty ways, one at a time; each must change the output
MARIADB=10.6 ./test_cycle_time.sh   # another MariaDB version (default 11.8)
```

The test cars cover the awkward cases on purpose: a car that bounced back from Ready and one sent back and still in work, one picked up without being made ready, comebacks after pickup, a pickup tapped by mistake and undone (one picked up later, one still waiting), demo and removed cars that go through every stage and must not appear anywhere, dealer cars caught by the flag and by the name rule, a repeat retail customer and a repeat Stock car for the rule check, cars with no customer name, a car with no tech, a parked car, cars aged exactly 7, 8, 14, 15, 30 and 31 days, a check-in dated in the future, two status changes stamped at the same instant, and a check-in typed in two days after the car arrived.

`--mutants` is there because a passing test only means something if it can fail. Each mutant is one deliberate break (a filter dropped, a bucket edge moved, the time zone line deleted, and so on), and each one must change the output. A mutant that errors, or a database that will not start, is reported as a broken test, never as a catch.

One break cannot be caught reliably: dropping the `idx` tiebreak for two status changes at the same instant, because the database may return tied rows in the right order by luck. The test checks a reversed tiebreak instead.

## Files

- `cycle_time.sql`: the analysis. Read-only: `SELECT` statements plus two session settings.
- `test_cycle_time.sh`: the test runner.
- `test_cars.py`: the made-up cars, and the second working of every answer in plain Python.
- `cycle_time.expected.txt`: the expected output. It is written from the SQL's own output, which is why `test_cars.py` has to agree with it independently.

## How it was built

I designed the analysis and the test cases and directed the build with AI coding tools. An independent review of an earlier version found four defects that produced wrong numbers, including the stale-timestamp problem above. A second review found that the test missed several of its own claims: four deliberate breaks went through it unnoticed. The test cars and `--mutants` were added to close that. A third review, by a reviewer who had not seen the earlier ones, found that an undone pickup was counted as a comeback, that a future-dated check-in fell out of the aging buckets, and that the expected file was only ever checked by the SQL that wrote it. Those are fixed, and the second working exists because of that last point.
