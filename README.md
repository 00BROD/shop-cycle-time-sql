# Shop cycle-time analysis in SQL

How long does a car sit in each stage of an auto repair shop, and where does the waiting time go?

This is the SQL I wrote to answer that for a repair shop's vehicle tracker, plus a test that checks every query against nine made-up cars with hand-worked answers.

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
| 2 | How long from check-in to ready, and from ready to pickup, by month? | grouped by pickup month, median per segment |
| 3 | How old are the cars on the lot right now? | aging buckets: 0-7, 8-14, 15-30, 30+ days |
| 4 | How many cars are made ready per week? | distinct cars per ISO week |
| 5 | How often does a car move backward a stage? | stage positions compared with `FIELD()` |

## Decisions worth explaining

- **Timings come from the status log, not the "ready on" and "picked up on" columns.** The app stamps those columns once and never updates them, so they go stale when a car bounces back from Ready or is re-opened after pickup. An early version that used them could report a negative ready-to-pickup time.
- **Cars still sitting in a stage are counted, up to now.** Leaving them out would hide the worst waits. Each stage reports `open_now`, so a reader can see when an average is still growing.
- **Monthly cycle time is grouped by the month the car left.** Grouping by check-in month makes the newest month look fast, because its slow cars have not left yet.
- **Gaps are counted, not dropped.** Cars picked up without ever being marked Ready, and cars re-opened after pickup, are not timed but are reported in their own columns.
- **Median and 90th percentile sit next to the average.** One car waiting five weeks on a part moves the average a long way.

## Known limits

- Hours are wall-clock: nights and weekends count.
- A no-show car counts as waiting until someone removes it or marks it picked up.
- The Dealer rule falls back on matching customer names for cars checked in before the "Stock" flag existed. Query 0 exists to check that rule.
- The per-tech weekly count uses the tech assigned today, so it is not safe for ranking technicians.

## Sample output (made-up cars)

Time in each stage, from the test data:

```
+---------+------------------+--------+----------+---------+------------+---------+---------------+
| segment | stage            | stints | open_now | avg_hrs | median_hrs | p90_hrs | total_car_hrs |
+---------+------------------+--------+----------+---------+------------+---------+---------------+
| Retail  | Checked In       |      4 |        0 |    10.0 |        7.0 |    19.8 |            40 |
| Retail  | Diagnosing       |      1 |        0 |    24.0 |       24.0 |    24.0 |            24 |
| Retail  | Waiting Parts    |      1 |        0 |    48.0 |       48.0 |    48.0 |            48 |
| Retail  | In Progress      |      4 |        1 |    16.8 |        8.0 |    36.6 |            67 |
| Retail  | QC / Test Drive  |      2 |        0 |     1.5 |        1.5 |     1.9 |             3 |
| Retail  | Ready for Pickup |      2 |        0 |    17.0 |       17.0 |    22.6 |            34 |
| Dealer  | Checked In       |      3 |        1 |    33.7 |       24.0 |    62.4 |           101 |
| Dealer  | Diagnosing       |      1 |        0 |    96.0 |       96.0 |    96.0 |            96 |
| Dealer  | Waiting Parts    |      1 |        1 |   840.0 |      840.0 |   840.0 |           840 |
| Dealer  | In Progress      |      2 |        0 |     4.0 |        4.0 |     4.8 |             8 |
| Dealer  | Ready for Pickup |      2 |        0 |     3.5 |        3.5 |     4.7 |             7 |
+---------+------------------+--------+----------+---------+------------+---------+---------------+
```

The full expected output for all queries is in `cycle_time.expected.txt`.

## Run the test

Needs Docker. It starts a throwaway MariaDB 11.8 container, loads nine made-up cars, runs every query, and compares the output with the expected file.

```
./test_cycle_time.sh
```

The test cars cover the awkward cases on purpose: a car that bounced back from Ready, one picked up without being marked Ready, one re-opened after pickup, a demo car and a removed car that must not appear anywhere, and dealer cars caught by the flag and by the name rule.

## Files

- `cycle_time.sql`: the analysis. Read-only: `SELECT` statements plus two session settings.
- `test_cycle_time.sh`: the test, with the made-up cars inline.
- `cycle_time.expected.txt`: the hand-checked expected output.

## How it was built

I designed the analysis and the test cases and directed the build with AI coding tools. An independent review of an earlier version found four defects that produced wrong numbers, including the stale-timestamp problem above. The test now covers bounced and re-opened cars.
