-- Auto repair shop floor: cycle-time analysis, split Dealer vs Retail
-- MariaDB 10.3.3+ (tested on 11.8). Read-only: SELECTs plus two session settings.
--
-- Tables (Frappe naming):
--   `tabRepair Order`             one car visit. status, tech_name, checked_in_on, plate, customer_name
--   `tabRepair Order Status Log`  one row per stage change. parent = RO name, at, from_status, to_status
--
-- Stage ladder: Checked In > Diagnosing > Waiting Approval > Waiting Parts >
--   In Progress > QC / Test Drive > Ready for Pickup > Picked Up
--
-- All timings come from the status log, not from the ready_on / picked_up_on columns: the
-- app stamps those once and never updates them, so they go stale when a
-- car bounces back from Ready or is re-opened after pickup.
--
-- Run it read-only against the tracker's database:
--   mariadb <database> -t < cycle_time.sql
-- Check the SQL itself anywhere with Docker (throwaway database, made-up cars):
--   ./test_cycle_time.sh
--
-- Queries 1-5 output aggregates only, safe to screenshot. Queries 0a/0b print customer
-- names: keep that output private.
--
-- KNOWN LIMITS (say these out loud when presenting the numbers):
--   * Hours are wall-clock: nights, weekends and the one-hour daylight-saving shifts count.
--   * A no-show or quote-only car counts as waiting until someone takes it off the floor
--     in the app (Remove) or marks it Picked Up. Removed cars are left out of everything.
--   * Dealer = marked Stock (whose_car, as it is set today) OR caught by the name rule
--     below. Cars checked in before the Stock field existed rely on the name rule alone.
--   * A pickup undone straight back to Ready (Picked Up -> Ready for Pickup) is read as a
--     mis-tap: the car never left. A pickup followed by any work stage is read as a comeback
--     and starts a new visit, even if it was a mis-tap too. Query 5 lists both kinds.
--   * Every query repeats the same `ro` block on purpose: demo and removed cars out,
--     segment worked out.
--   * Needs the `removed`, `whose_car` and `parked` columns. On an older install a query
--     errors and prints nothing: no wrong numbers are shown.


-- CLOCK: the app stores shop-local times, but the database server's own clock is UTC.
-- Without this line NOW() runs 7-8 hours ahead and every "still waiting" figure is too long.
-- Must match the site's time zone (System Settings > Time Zone). Session-only; changes no data.
-- If it errors with "Unknown or incorrect time zone", stop: do not run the rest without it.
SET time_zone = 'America/Los_Angeles';


-- DEALER RULE: the one place to edit ----------------------------------------------------
-- Shortcut: whose_car = 'Stock' is the real field, but older cars were checked in before it
-- existed, so a customer-name match backs it up.
-- Ceiling: an unmarked dealer car whose name lacks these words counts as Retail (query 0b
-- finds repeat ones); spelling variants such as "AutoSales" need their own entry. It matches
-- anywhere in the name, so "Wholesale Tire" counts as Dealer: query 0a is where to catch that.
-- Upgrade path: once every dealer car is marked Stock, delete the REGEXP half of each `ro` block.
SET @dealer_re = 'AUTO SALES|AUTO GROUP|CAR SALES|DEALER|WHOLESALE|AUTO MART|MOTOR CARS|AUTO BROKER';


-- 0a. CHECK THE RULE: names counted as Dealer (do not screenshot) ----------------------
SELECT UPPER(TRIM(customer_name)) AS dealer_name, COUNT(*) AS visits
FROM `tabRepair Order`
WHERE COALESCE(plate, '') NOT LIKE 'DEMO%' AND COALESCE(removed, 0) = 0 AND UPPER(customer_name) REGEXP @dealer_re
GROUP BY dealer_name
ORDER BY visits DESC, dealer_name;

-- 0b. CHECK THE RULE: repeat customers counted as Retail (do not screenshot) ------------
-- A name here that is really a dealer: add a word from it to @dealer_re.
SELECT UPPER(TRIM(customer_name)) AS retail_name, COUNT(*) AS visits
FROM `tabRepair Order`
WHERE COALESCE(plate, '') NOT LIKE 'DEMO%' AND COALESCE(removed, 0) = 0
  AND COALESCE(whose_car, '') <> 'Stock'
  AND TRIM(COALESCE(customer_name, '')) <> ''   -- cars with no name are not one repeat customer
  AND NOT (UPPER(COALESCE(customer_name, '')) REGEXP @dealer_re)
GROUP BY retail_name
HAVING visits >= 2
ORDER BY visits DESC, retail_name;


-- 0c. HOW THE SPLIT WAS MADE (names-free, safe to show) -------------------------------
-- marked_stock = flagged Stock at check-in; by_name = caught by the name rule above.
WITH ro AS (
  SELECT o.*, IF(o.whose_car = 'Stock' OR UPPER(COALESCE(o.customer_name, '')) REGEXP @dealer_re, 'Dealer', 'Retail') AS segment
  FROM `tabRepair Order` o
  WHERE COALESCE(o.plate, '') NOT LIKE 'DEMO%' AND COALESCE(o.removed, 0) = 0
)
SELECT segment, COUNT(*) AS cars,
  SUM(COALESCE(whose_car, '') = 'Stock')                          AS marked_stock,
  SUM(UPPER(COALESCE(customer_name, '')) REGEXP @dealer_re)       AS by_name
FROM ro GROUP BY segment ORDER BY segment DESC;


-- 1. TIME IN EACH STAGE ---------------------------------------------------------------
-- A stint = from one log row to the next log row on the same car. A car still sitting in
-- a stage has no next row; its stint is counted up to NOW() and tallied in `open_now`.
-- Leaving those out would hide the worst waits (the cars still stuck), so a stage with a
-- high open_now has averages that are still growing: read them as "at least this long".
-- The first stint starts at checked_in_on when someone typed in an earlier arrival than the
-- moment they saved the car (the app stamps the first log row at save time). Query 2 uses
-- the same arrival, so the two queries agree.
WITH ro AS (
  SELECT o.*, IF(o.whose_car = 'Stock' OR UPPER(COALESCE(o.customer_name, '')) REGEXP @dealer_re, 'Dealer', 'Retail') AS segment
  FROM `tabRepair Order` o
  WHERE COALESCE(o.plate, '') NOT LIKE 'DEMO%' AND COALESCE(o.removed, 0) = 0
),
stints AS (
  SELECT
    ro.segment,
    l.to_status AS stage,
    IF(l.from_status IS NULL, LEAST(COALESCE(ro.checked_in_on, l.at), l.at), l.at) AS entered,
    LEAD(l.at) OVER (PARTITION BY l.parent ORDER BY l.at, l.idx) AS left_at
  FROM `tabRepair Order Status Log` l
  JOIN ro ON ro.name = l.parent
),
timed AS (
  SELECT segment, stage, left_at IS NULL AS is_open,
    TIMESTAMPDIFF(MINUTE, entered, COALESCE(left_at, NOW())) / 60 AS hrs
  FROM stints
  WHERE stage <> 'Picked Up'
),
ranked AS (
  SELECT segment, stage, hrs, is_open,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY hrs) OVER (PARTITION BY segment, stage) AS p50,
    PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY hrs) OVER (PARTITION BY segment, stage) AS p90
  FROM timed
)
SELECT
  segment,
  stage,
  COUNT(*)              AS stints,
  SUM(is_open)          AS open_now,
  ROUND(AVG(hrs), 1)    AS avg_hrs,
  ROUND(MAX(p50), 1)    AS median_hrs,
  ROUND(MAX(p90), 1)    AS p90_hrs,
  ROUND(SUM(hrs), 0)    AS total_car_hrs   -- where the shop's waiting time actually goes
FROM ranked
GROUP BY segment, stage
ORDER BY segment DESC,
  FIELD(stage, 'Checked In','Diagnosing','Waiting Approval','Waiting Parts',
               'In Progress','QC / Test Drive','Ready for Pickup'), stage;


-- 2. END-TO-END CYCLE TIME, ONE VISIT AT A TIME --------------------------------------
-- A visit runs from arrival to pickup. A car that comes back for work after a pickup starts
-- a new visit on the day it came back, so comebacks are timed too, the same way query 3 ages
-- them. A pickup undone straight back to Ready is a mis-tap, not a comeback: same visit.
--   ready  = when the car became ready and stayed ready: the first Ready for Pickup row
--            after the visit's last work stage. A car sent back to work from Ready was not
--            ready, and a car in work now has no ready time yet.
--   picked = the pickup that stuck (not one undone back to Ready)
-- Each half is grouped by the month of the event that ENDS what it measures, so a month's
-- numbers do not keep moving (grouping by check-in month makes the newest month look fast).
-- Ceiling: a car made ready in one month and sent back to work the next drops out of the
-- first month's 2a row. Rare; read 2a's newest month as provisional.

-- 2a. SHOP SPEED: arrival -> ready, by the month the car was made READY.
-- Cars still waiting for their owner count here (still_awaiting_pickup).
WITH ro AS (
  SELECT o.*, IF(o.whose_car = 'Stock' OR UPPER(COALESCE(o.customer_name, '')) REGEXP @dealer_re, 'Dealer', 'Retail') AS segment
  FROM `tabRepair Order` o
  WHERE COALESCE(o.plate, '') NOT LIKE 'DEMO%' AND COALESCE(o.removed, 0) = 0
),
logrows AS (
  SELECT ro.name, ro.segment, ro.checked_in_on, l.at, l.to_status,
    SUM(COALESCE(l.from_status = 'Picked Up' AND l.to_status <> 'Ready for Pickup', 0))
      OVER (PARTITION BY l.parent ORDER BY l.at, l.idx ROWS UNBOUNDED PRECEDING) AS visit,
    SUM(l.to_status NOT IN ('Ready for Pickup', 'Picked Up'))
      OVER (PARTITION BY l.parent ORDER BY l.at, l.idx ROWS UNBOUNDED PRECEDING) AS work_run,
    LEAD(l.to_status) OVER (PARTITION BY l.parent ORDER BY l.at, l.idx)          AS next_status
  FROM `tabRepair Order Status Log` l
  JOIN ro ON ro.name = l.parent
),
marked AS (
  SELECT r.*, MAX(work_run) OVER (PARTITION BY name, visit) AS last_run
  FROM logrows r
),
visits AS (
  SELECT name, segment, visit,
    IF(visit = 0, LEAST(COALESCE(MAX(checked_in_on), MIN(at)), MIN(at)), MIN(at))  AS started,
    MIN(IF(to_status = 'Ready for Pickup' AND work_run = last_run, at, NULL))       AS ready,
    MAX(IF(to_status = 'Picked Up'
           AND COALESCE(next_status, '') <> 'Ready for Pickup', at, NULL))          AS picked
  FROM marked
  GROUP BY name, segment, visit
),
timed AS (
  SELECT DATE_FORMAT(ready, '%Y-%m') AS ready_month, segment, visit, picked,
    TIMESTAMPDIFF(MINUTE, started, ready) / 1440 AS days
  FROM visits WHERE ready IS NOT NULL
),
ranked AS (
  SELECT t.*,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY days) OVER (PARTITION BY ready_month, segment) AS p50,
    PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY days) OVER (PARTITION BY ready_month, segment) AS p90
  FROM timed t
)
SELECT ready_month, segment,
  COUNT(*)                AS visits_made_ready,
  SUM(visit > 0)          AS comebacks,
  SUM(picked IS NULL)     AS still_awaiting_pickup,
  ROUND(AVG(days), 1)     AS avg_days_to_ready,
  ROUND(MAX(p50), 1)      AS median_days_to_ready,
  ROUND(MAX(p90), 1)      AS p90_days_to_ready
FROM ranked
GROUP BY ready_month, segment
ORDER BY ready_month, segment DESC;

-- 2b. CUSTOMER SPEED: ready -> picked up, by the month the car was PICKED UP.
-- missing_ready = picked up without being made ready first: not timed, but counted.
WITH ro AS (
  SELECT o.*, IF(o.whose_car = 'Stock' OR UPPER(COALESCE(o.customer_name, '')) REGEXP @dealer_re, 'Dealer', 'Retail') AS segment
  FROM `tabRepair Order` o
  WHERE COALESCE(o.plate, '') NOT LIKE 'DEMO%' AND COALESCE(o.removed, 0) = 0
),
logrows AS (
  SELECT ro.name, ro.segment, ro.checked_in_on, l.at, l.to_status,
    SUM(COALESCE(l.from_status = 'Picked Up' AND l.to_status <> 'Ready for Pickup', 0))
      OVER (PARTITION BY l.parent ORDER BY l.at, l.idx ROWS UNBOUNDED PRECEDING) AS visit,
    SUM(l.to_status NOT IN ('Ready for Pickup', 'Picked Up'))
      OVER (PARTITION BY l.parent ORDER BY l.at, l.idx ROWS UNBOUNDED PRECEDING) AS work_run,
    LEAD(l.to_status) OVER (PARTITION BY l.parent ORDER BY l.at, l.idx)          AS next_status
  FROM `tabRepair Order Status Log` l
  JOIN ro ON ro.name = l.parent
),
marked AS (
  SELECT r.*, MAX(work_run) OVER (PARTITION BY name, visit) AS last_run
  FROM logrows r
),
visits AS (
  SELECT name, segment, visit,
    IF(visit = 0, LEAST(COALESCE(MAX(checked_in_on), MIN(at)), MIN(at)), MIN(at))  AS started,
    MIN(IF(to_status = 'Ready for Pickup' AND work_run = last_run, at, NULL))       AS ready,
    MAX(IF(to_status = 'Picked Up'
           AND COALESCE(next_status, '') <> 'Ready for Pickup', at, NULL))          AS picked
  FROM marked
  GROUP BY name, segment, visit
),
picked AS (
  SELECT DATE_FORMAT(picked, '%Y-%m') AS pickup_month, segment, visit, ready IS NOT NULL AS is_timed,
    TIMESTAMPDIFF(MINUTE, ready, picked) / 1440 AS days
  FROM visits WHERE picked IS NOT NULL
),
ranked AS (
  SELECT p.*,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY days) OVER (PARTITION BY pickup_month, segment, is_timed) AS p50,
    PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY days) OVER (PARTITION BY pickup_month, segment, is_timed) AS p90
  FROM picked p
)
SELECT pickup_month, segment,
  COUNT(*)                                AS visits_picked_up,
  SUM(is_timed)                           AS visits_timed,
  ROUND(AVG(IF(is_timed, days, NULL)), 1) AS avg_days_ready_to_pickup,
  ROUND(MAX(IF(is_timed, p50, NULL)), 1)  AS median_days_ready_to_pickup,
  ROUND(MAX(IF(is_timed, p90, NULL)), 1)  AS p90_days_ready_to_pickup,
  SUM(NOT is_timed)                       AS missing_ready,
  SUM(visit > 0)                          AS comebacks
FROM ranked
GROUP BY pickup_month, segment
ORDER BY pickup_month, segment DESC;


-- 3. AGING: CARS ON THE LOT RIGHT NOW --------------------------------------------------
-- Whole 24-hour days, the same rule the shop's daily board uses (a check-in dated in the
-- future counts as 0 days, as it does there), with one difference: a car that came back
-- for work after a pickup is aged from the day it came back, not from its first visit.
-- The board ages it from the first visit.
-- Retail 31+ is the list to ask about each morning; dealer cars may sit by arrangement,
-- and `parked` says how many cars in the row someone marked Parked On Purpose in the app.
WITH ro AS (
  SELECT o.*, IF(o.whose_car = 'Stock' OR UPPER(COALESCE(o.customer_name, '')) REGEXP @dealer_re, 'Dealer', 'Retail') AS segment
  FROM `tabRepair Order` o
  WHERE COALESCE(o.plate, '') NOT LIKE 'DEMO%' AND COALESCE(o.removed, 0) = 0
),
open_cars AS (
  SELECT
    ro.segment, ro.status, COALESCE(ro.parked, 0) AS parked,
    GREATEST(0, TIMESTAMPDIFF(DAY, COALESCE(
        (SELECT MAX(l.at) FROM `tabRepair Order Status Log` l
          WHERE l.parent = ro.name AND l.from_status = 'Picked Up'
            AND l.to_status <> 'Ready for Pickup'),
        ro.checked_in_on, ro.creation), NOW())) AS days_in_shop,
    TIMESTAMPDIFF(DAY, (SELECT MAX(l.at) FROM `tabRepair Order Status Log` l
                        WHERE l.parent = ro.name), NOW()) AS days_in_stage
  FROM ro
  WHERE ro.status <> 'Picked Up'
)
SELECT
  segment,
  status AS stage,
  COUNT(*)                                  AS cars,
  SUM(days_in_shop BETWEEN 0 AND 7)         AS `0_7d`,
  SUM(days_in_shop BETWEEN 8 AND 14)        AS `8_14d`,
  SUM(days_in_shop BETWEEN 15 AND 30)       AS `15_30d`,
  SUM(days_in_shop > 30)                    AS `31d_plus`,
  SUM(parked)                               AS parked,
  ROUND(AVG(days_in_stage), 1)              AS avg_days_in_this_stage,
  MAX(days_in_stage)                        AS oldest_in_stage_days
FROM open_cars
GROUP BY segment, status
ORDER BY segment DESC,
  FIELD(status, 'Checked In','Diagnosing','Waiting Approval','Waiting Parts',
                'In Progress','QC / Test Drive','Ready for Pickup'), status;


-- 4. CARS MADE READY PER WEEK, BY ASSIGNED TECH ----------------------------------------
-- A car marked ready twice in one week counts once.
-- Caution: `tech` is whoever the car is assigned to TODAY. Reassign a car and its past
-- weeks move to the new tech. Fine for shop-wide weekly throughput; do not use it to rank
-- technicians. Cars picked up without being marked Ready do not appear here.
-- Every arrival at Ready counts, including a car later sent back to work; query 2a counts
-- only the Ready that stuck, so the two can differ by the bounced cars.
WITH ro AS (
  SELECT o.*, IF(o.whose_car = 'Stock' OR UPPER(COALESCE(o.customer_name, '')) REGEXP @dealer_re, 'Dealer', 'Retail') AS segment
  FROM `tabRepair Order` o
  WHERE COALESCE(o.plate, '') NOT LIKE 'DEMO%' AND COALESCE(o.removed, 0) = 0
)
SELECT
  YEARWEEK(l.at, 3)                                           AS iso_week,
  COALESCE(NULLIF(ro.tech_name, ''), '(unassigned)')          AS tech,
  COUNT(DISTINCT IF(ro.segment = 'Retail', l.parent, NULL))   AS retail_ready,
  COUNT(DISTINCT IF(ro.segment = 'Dealer', l.parent, NULL))   AS dealer_ready,
  COUNT(DISTINCT l.parent)                                    AS cars_ready
FROM `tabRepair Order Status Log` l
JOIN ro ON ro.name = l.parent
WHERE l.to_status = 'Ready for Pickup'
GROUP BY iso_week, tech
ORDER BY iso_week, tech;


-- 5. BACKWARD MOVES ---------------------------------------------------------------------
-- A car sent to an earlier stage. Read each row for what it is; they are not all rework:
--   QC / Test Drive -> In Progress        failed test drive (rework)
--   In Progress -> Waiting Parts          wrong or missing part
--   In Progress -> Waiting Approval       more work found, waiting on the customer
--   Picked Up -> anything                 a comeback, or a pickup marked by mistake
-- Rows with a status that is not on today's ladder (e.g. after a stage rename) are left out.
WITH ro AS (
  SELECT o.*, IF(o.whose_car = 'Stock' OR UPPER(COALESCE(o.customer_name, '')) REGEXP @dealer_re, 'Dealer', 'Retail') AS segment
  FROM `tabRepair Order` o
  WHERE COALESCE(o.plate, '') NOT LIKE 'DEMO%' AND COALESCE(o.removed, 0) = 0
),
moves AS (
  SELECT ro.segment, l.parent, l.from_status, l.to_status,
    FIELD(l.from_status, 'Checked In','Diagnosing','Waiting Approval','Waiting Parts',
                         'In Progress','QC / Test Drive','Ready for Pickup','Picked Up') AS from_pos,
    FIELD(l.to_status,   'Checked In','Diagnosing','Waiting Approval','Waiting Parts',
                         'In Progress','QC / Test Drive','Ready for Pickup','Picked Up') AS to_pos
  FROM `tabRepair Order Status Log` l
  JOIN ro ON ro.name = l.parent
)
SELECT segment, from_status, to_status,
  COUNT(*)               AS moves,
  COUNT(DISTINCT parent) AS cars
FROM moves
WHERE from_pos > 0 AND to_pos > 0 AND to_pos < from_pos
GROUP BY segment, from_status, to_status
ORDER BY moves DESC, segment DESC, from_pos, to_pos;
