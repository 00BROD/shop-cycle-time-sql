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
--   * Dealer = marked Stock at check-in (whose_car) OR caught by the name rule below. Cars
--     checked in before the Stock field existed rely on the name rule alone.
--   * Every query repeats the same `ro` block on purpose: demo and removed cars out,
--     segment worked out.
--   * Needs the `removed` and `whose_car` columns. On an older install the first query
--     errors: nothing wrong is shown.


-- CLOCK: the app stores shop-local times, but the database server's own clock is UTC.
-- Without this line NOW() runs 7-8 hours ahead and every "still waiting" figure is too long.
-- Must match the site's time zone (System Settings > Time Zone). Session-only; changes no data.
-- If it errors with "Unknown or incorrect time zone", stop: do not run the rest without it.
SET time_zone = 'America/Los_Angeles';


-- DEALER RULE: the one place to edit ----------------------------------------------------
-- Shortcut: whose_car = 'Stock' is the real field, but older cars were checked in before it
-- existed, so a customer-name match backs it up.
-- Ceiling: an unmarked dealer car whose name lacks these words counts as Retail (query 0b
-- finds repeat ones); spelling variants such as "AutoSales" need their own entry.
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
WITH ro AS (
  SELECT o.*, IF(o.whose_car = 'Stock' OR UPPER(COALESCE(o.customer_name, '')) REGEXP @dealer_re, 'Dealer', 'Retail') AS segment
  FROM `tabRepair Order` o
  WHERE COALESCE(o.plate, '') NOT LIKE 'DEMO%' AND COALESCE(o.removed, 0) = 0
),
stints AS (
  SELECT
    ro.segment,
    l.to_status AS stage,
    l.at AS entered,
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


-- 2. END-TO-END CYCLE TIME BY PICKUP MONTH --------------------------------------------
-- Grouped by the month the car LEFT, so a month's numbers do not change later (grouping
-- by check-in month makes the newest month look fast: its slow cars have not left yet).
--   picked up = the car's last Picked Up log row
--   ready     = its last Ready for Pickup row before that (after any bounce back to work)
--   days_to_ready            check-in -> ready      (the shop's speed)
--   days_ready_to_pickup     ready -> picked up     (the customer's speed)
-- Not timed, but counted so the gap is visible:
--   missing_ready  picked up without ever being marked Ready
--   reopened       re-opened after a pickup; its check-in date belongs to the first visit
WITH ro AS (
  SELECT o.*, IF(o.whose_car = 'Stock' OR UPPER(COALESCE(o.customer_name, '')) REGEXP @dealer_re, 'Dealer', 'Retail') AS segment
  FROM `tabRepair Order` o
  WHERE COALESCE(o.plate, '') NOT LIKE 'DEMO%' AND COALESCE(o.removed, 0) = 0
),
ends AS (
  SELECT ro.name, ro.segment,
    COALESCE(ro.checked_in_on, ro.creation)                       AS checked_in,
    MAX(IF(l.to_status = 'Picked Up', l.at, NULL))                AS picked,
    COALESCE(SUM(l.from_status = 'Picked Up'), 0) > 0             AS reopened
  FROM ro
  JOIN `tabRepair Order Status Log` l ON l.parent = ro.name
  WHERE ro.status = 'Picked Up'
  GROUP BY ro.name, ro.segment, checked_in
),
cars AS (
  SELECT e.*,
    (SELECT MAX(l.at) FROM `tabRepair Order Status Log` l
      WHERE l.parent = e.name AND l.to_status = 'Ready for Pickup' AND l.at <= e.picked) AS ready
  FROM ends e
),
flagged AS (
  SELECT DATE_FORMAT(picked, '%Y-%m') AS month, segment, reopened,
    (NOT reopened AND (ready IS NULL OR ready < checked_in)) AS missing_ready,
    (NOT reopened AND ready IS NOT NULL AND ready >= checked_in) AS is_timed,
    TIMESTAMPDIFF(MINUTE, checked_in, ready) / 1440 AS days_to_ready,
    TIMESTAMPDIFF(MINUTE, ready, picked)     / 1440 AS days_to_pickup
  FROM cars
),
med AS (
  SELECT DISTINCT month, segment,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY days_to_ready)
      OVER (PARTITION BY month, segment) AS p50_ready
  FROM flagged WHERE is_timed
)
SELECT f.month, f.segment,
  COUNT(*)                                            AS cars_picked_up,
  SUM(f.is_timed)                                     AS cars_timed,
  ROUND(AVG(IF(f.is_timed, f.days_to_ready, NULL)), 1)  AS avg_days_to_ready,
  ROUND(MAX(med.p50_ready), 1)                        AS median_days_to_ready,
  ROUND(AVG(IF(f.is_timed, f.days_to_pickup, NULL)), 1) AS avg_days_ready_to_pickup,
  SUM(f.missing_ready)                                AS missing_ready,
  SUM(f.reopened)                                     AS reopened
FROM flagged f
LEFT JOIN med ON med.month <=> f.month AND med.segment = f.segment
GROUP BY f.month, f.segment
ORDER BY f.month, f.segment DESC;


-- 3. AGING: CARS ON THE LOT RIGHT NOW --------------------------------------------------
-- Whole 24-hour days, the same rule the shop's daily board uses, with one
-- difference: a car re-opened after pickup is aged from the day
-- it came back, not from its first visit. The board ages it from the first visit.
-- Retail 30+ is the list to ask about each morning; dealer cars may sit by arrangement.
WITH ro AS (
  SELECT o.*, IF(o.whose_car = 'Stock' OR UPPER(COALESCE(o.customer_name, '')) REGEXP @dealer_re, 'Dealer', 'Retail') AS segment
  FROM `tabRepair Order` o
  WHERE COALESCE(o.plate, '') NOT LIKE 'DEMO%' AND COALESCE(o.removed, 0) = 0
),
open_cars AS (
  SELECT
    ro.segment, ro.status,
    TIMESTAMPDIFF(DAY, COALESCE(
        (SELECT MAX(l.at) FROM `tabRepair Order Status Log` l
          WHERE l.parent = ro.name AND l.from_status = 'Picked Up'),
        ro.checked_in_on, ro.creation), NOW()) AS days_in_shop,
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
  SUM(days_in_shop > 30)                    AS `30d_plus`,
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
