# Shop cycle-time analysis in SQL

How long does a car sit in each stage of an auto repair shop, and where does the waiting time go?

This is the SQL I wrote to answer that for a repair shop's vehicle tracker, plus a test that runs every query on twenty made-up cars and compares the output with a hand-checked copy.

**Status:** the numbers shown here come from the made-up test cars. The queries have not been run on the shop's production data yet, and no shop or customer data is in this repo.

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
| 3 | How old are the cars on the lot right now? | aging buckets: 0-7, 8-14, 15-30, 31+ days |
| 4 | How many cars are made ready per week? | distinct cars per ISO week |
| 5 | How often does a car move backward a stage? | stage positions compared with `FIELD()` |

## Decisions worth explaining

- **Timings come from the status log, not the "ready on" and "picked up on" columns.** The app stamps those columns once and never updates them, so they go stale when a car bounces back from Ready or is re-opened after pickup. An early version that used them could report a negative ready-to-pickup time.
- **Cars still sitting in a stage are counted, up to now.** Leaving them out would hide the worst waits. Each stage reports `open_now`, so a reader can see when an average is still growing.
- **Each monthly number is grouped by the month of the event that ends it.** Shop speed (arrival to ready) goes by the month the car was made ready, so a finished car counts even while it waits for its owner. Customer speed (ready to pickup) goes by the month it was picked up. Grouping by check-in month makes the newest month look fast, because its slow cars have not finished yet.
- **A comeback is its own visit.** A car re-opened after pickup is timed from the day it came back, the same way the aging query counts it.
- **Ready means the Ready that stuck.** A car sent back to work from Ready was not ready; only its last Ready, followed by nothing but a pickup, counts in query 2.
- **A backdated check-in starts the clock.** The app stamps the first log row when the car is saved, so when someone types in an earlier arrival, queries 1 and 2 both use that arrival.
- **Gaps are counted, not dropped.** Cars picked up without being made ready are not timed but are reported in their own column.
- **Median and 90th percentile sit next to the average.** One car waiting five weeks on a part moves the average a long way.

## Known limits

- Hours are wall-clock: nights and weekends count.
- A no-show car counts as waiting until someone removes it or marks it picked up.
- The Dealer rule falls back on matching customer names for cars checked in before the "Stock" flag existed. Query 0 exists to check that rule.
- The per-tech weekly count uses the tech assigned today, so it is not safe for ranking technicians. It also counts every arrival at Ready, including cars later sent back, so it can run higher than query 2a.
- A car made ready in one month and sent back to work the next drops out of the first month's 2a row. Read the newest month as provisional.

## Sample output (made-up cars)

Time in each stage, from the test data:

```
+---------+------------------+--------+----------+---------+------------+---------+---------------+
| segment | stage            | stints | open_now | avg_hrs | median_hrs | p90_hrs | total_car_hrs |
+---------+------------------+--------+----------+---------+------------+---------+---------------+
| Retail  | Checked In       |     12 |        4 |   161.1 |       24.0 |   667.2 |          1933 |
| Retail  | Diagnosing       |      2 |        0 |    12.0 |       12.0 |    21.6 |            24 |
| Retail  | Waiting Parts    |      1 |        0 |    48.0 |       48.0 |    48.0 |            48 |
| Retail  | In Progress      |      6 |        2 |    19.7 |        8.0 |    48.0 |           118 |
| Retail  | QC / Test Drive  |      2 |        0 |     1.5 |        1.5 |     1.9 |             3 |
| Retail  | Ready for Pickup |      6 |        0 |    11.8 |       10.0 |    24.0 |            71 |
| Dealer  | Checked In       |      4 |        1 |    31.3 |       24.0 |    57.6 |           125 |
| Dealer  | Diagnosing       |      1 |        0 |    96.0 |       96.0 |    96.0 |            96 |
| Dealer  | Waiting Parts    |      1 |        1 |   840.0 |      840.0 |   840.0 |           840 |
| Dealer  | In Progress      |      2 |        0 |     4.0 |        4.0 |     4.8 |             8 |
| Dealer  | Ready for Pickup |      3 |        1 |    42.3 |        5.0 |    97.0 |           127 |
+---------+------------------+--------+----------+---------+------------+---------+---------------+
```

The full expected output for all queries is in `cycle_time.expected.txt`.

## Run the test

Needs Docker. It starts a throwaway MariaDB 11.8 container, pins the clock to a fixed moment, loads twenty made-up cars, runs every query, and compares the output with the expected file. It also passes on MariaDB 10.6 with Frappe's table collation (`utf8mb4_unicode_ci`).

```
./test_cycle_time.sh            # compare with the expected file
./test_cycle_time.sh --mutants  # break the SQL ten ways, one at a time; each must fail
```

The test cars cover the awkward cases on purpose: a car that bounced back from Ready and one sent back and still in work, one picked up without being made ready, comebacks after pickup, demo and removed cars that go through every stage and must not appear anywhere, dealer cars caught by the flag and by the name rule, a repeat retail customer and a repeat Stock car for the rule check, cars aged exactly 7, 8, 30 and 31 days, two status changes stamped at the same instant, and a check-in typed in after the car arrived.

`--mutants` is there because a passing test only means something if it can fail. Each mutant is one deliberate break (a filter dropped, a bucket edge moved, the time zone line deleted, and so on), and the test must catch every one.

## Files

- `cycle_time.sql`: the analysis. Read-only: `SELECT` statements plus two session settings.
- `test_cycle_time.sh`: the test, with the made-up cars inline.
- `cycle_time.expected.txt`: the expected output, written by `--update` and checked row by row against the test cars by hand.

## How it was built

I designed the analysis and the test cases and directed the build with AI coding tools. An independent review of an earlier version found four defects that produced wrong numbers, including the stale-timestamp problem above. A second review found that the test missed several of its own claims: four deliberate breaks went through it unnoticed. The test cars and `--mutants` were added to close that.
