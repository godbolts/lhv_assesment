-- =============================================================================
-- LHV AFC analytics case study - Marko Karilaid
-- Engine: PostgreSQL (pgAdmin 4). The file runs top to bottom; the CSV load in
-- section 0 is done once in the PSQL tool.
--
-- Contents
--   0) Data import            tables, CSV load, indexes, row counts
--   1) Shared preparation     transactions without reloaded duplicates
--   2) Proposal A             TM-07 tuning: solution, answers A1/A2, data quality
--   3) Proposal B             risk model v4: solution, answer B1, data quality
--
-- Main assumptions (each is repeated next to the query that uses it)
--   * Tables are loaded exactly as delivered, without keys or constraints,
--     so that data problems stay visible and are handled in SQL.
--   * Reloaded duplicate rows are removed; split payments are kept.
--   * "Incoming transfers" (TM-07) are completed transfers, by booked_at month.
--   * A transfer's destination country (F09) is the country in the payment,
--     or the counterparty bank's country when the payment has none.
--   * Risk bands: LOW below 5, MEDIUM below 9, MEDIUM-HIGH below 12, HIGH 12+.
-- =============================================================================


-- =============================================================================
-- 0) DATA IMPORT
-- =============================================================================

-- A separate schema for the case study.
CREATE SCHEMA IF NOT EXISTS afc;
SET search_path TO afc;

-- One table per CSV file, with columns and types following the data dictionary.
-- No primary keys: the documented keys are not unique in every table.
-- IF NOT EXISTS makes the section safe to run again without touching loaded data.
CREATE TABLE IF NOT EXISTS customers (
    customer_id        integer,
    customer_type      text,        
    residency_country  text,        
    onboarding_date    date,
    status             text,        
    closed_date        date
);

CREATE TABLE IF NOT EXISTS transactions (
    transaction_id         bigint,
    customer_id            integer,
    counterparty_id        bigint,  
    direction              text,    
    amount_eur             numeric(14,2),
    status                 text,    
    counterparty_country   text,
    counterparty_bank_bic  text,    
    booked_at              timestamp,
    exported_at            timestamp,
    load_date              date
);

CREATE TABLE IF NOT EXISTS banks (
    bic               text,
    bank_name         text,
    country           text,
    institution_type  text          
);

CREATE TABLE IF NOT EXISTS high_risk_countries (
    country  text
);

CREATE TABLE IF NOT EXISTS monitoring_alerts (
    alert_id           bigint,
    rule_code          text,        
    scenario_type      text,        
    customer_id        integer,
    period_month       text,        
    created_at         timestamp,
    status             text,        
    status_changed_at  timestamp,
    load_date          date
);

CREATE TABLE IF NOT EXISTS alert_statuses (
    status   text,
    outcome  text                   
);

CREATE TABLE IF NOT EXISTS risk_factors (
    factor_code  text,              
    description  text,
    weight       numeric(4,2)
);

CREATE TABLE IF NOT EXISTS risk_factor_scores (
    customer_id  integer,
    score_date   date,              
    factor_code  text,
    score        smallint,          
    loaded_at    timestamp
);

CREATE TABLE IF NOT EXISTS risk_snapshot (
    customer_id    integer,
    snapshot_date  date,            
    total_score    numeric(6,2),
    risk_band      text,            
    model_version  text
);

-- Commands for the pgAdmin PSQL tool that load the CSV files into the tables.
-- Run them there (not in the Query Tool) after the tables exist, then continue
-- with the indexes below.

--\copy afc.customers           FROM 'C:/Users/mkari/case_study_candidate/csv/customers.csv'           WITH (FORMAT csv, HEADER true)
--\copy afc.transactions        FROM 'C:/Users/mkari/case_study_candidate/csv/transactions.csv'        WITH (FORMAT csv, HEADER true)
--\copy afc.banks               FROM 'C:/Users/mkari/case_study_candidate/csv/banks.csv'               WITH (FORMAT csv, HEADER true)
--\copy afc.high_risk_countries FROM 'C:/Users/mkari/case_study_candidate/csv/high_risk_countries.csv' WITH (FORMAT csv, HEADER true)
--\copy afc.monitoring_alerts   FROM 'C:/Users/mkari/case_study_candidate/csv/monitoring_alerts.csv'   WITH (FORMAT csv, HEADER true)
--\copy afc.alert_statuses      FROM 'C:/Users/mkari/case_study_candidate/csv/alert_statuses.csv'      WITH (FORMAT csv, HEADER true)
--\copy afc.risk_factors        FROM 'C:/Users/mkari/case_study_candidate/csv/risk_factors.csv'        WITH (FORMAT csv, HEADER true)
--\copy afc.risk_factor_scores  FROM 'C:/Users/mkari/case_study_candidate/csv/risk_factor_scores.csv'  WITH (FORMAT csv, HEADER true)
--\copy afc.risk_snapshot       FROM 'C:/Users/mkari/case_study_candidate/csv/risk_snapshot.csv'       WITH (FORMAT csv, HEADER true)

-- Non-unique indexes to speed up the joins and filters used below.
CREATE INDEX IF NOT EXISTS ix_tx_customer_booked ON transactions (customer_id, booked_at);
CREATE INDEX IF NOT EXISTS ix_tx_transaction_id  ON transactions (transaction_id);
CREATE INDEX IF NOT EXISTS ix_alerts_rule_period ON monitoring_alerts (rule_code, period_month, customer_id);
CREATE INDEX IF NOT EXISTS ix_rfs_customer_date  ON risk_factor_scores (customer_id, score_date, factor_code);
CREATE INDEX IF NOT EXISTS ix_snap_customer_date ON risk_snapshot (customer_id, snapshot_date);
ANALYZE;

-- Row counts after loading, compared with the row counts of the CSV files.
SELECT 'customers' AS table_name, count(*) AS row_count, 6000 AS expected FROM customers
UNION ALL SELECT 'transactions',        count(*), 342318 FROM transactions
UNION ALL SELECT 'banks',               count(*), 274    FROM banks
UNION ALL SELECT 'high_risk_countries', count(*), 25     FROM high_risk_countries
UNION ALL SELECT 'monitoring_alerts',   count(*), 6953   FROM monitoring_alerts
UNION ALL SELECT 'alert_statuses',      count(*), 5      FROM alert_statuses
UNION ALL SELECT 'risk_factors',        count(*), 8      FROM risk_factors
UNION ALL SELECT 'risk_factor_scores',  count(*), 141128 FROM risk_factor_scores
UNION ALL SELECT 'risk_snapshot',       count(*), 69458  FROM risk_snapshot;


-- =============================================================================
-- 1) SHARED PREPARATION (used by both proposals)
-- =============================================================================
-- Transactions with reloaded duplicates removed. About 25,000 transactions
-- appear twice, identical except for load_date, so the first load is kept.
-- Transactions with two different counterparties are split payments with
-- separate amounts and are kept as they are.
CREATE OR REPLACE VIEW tx_clean AS
SELECT DISTINCT ON (transaction_id, counterparty_id) *
FROM transactions
ORDER BY transaction_id, counterparty_id, load_date;   -- keep the first load


-- =============================================================================
-- 2) PROPOSAL A: tuning monitoring rule TM-07 (questions A1 and A2)
-- 2.1) SOLUTION
-- =============================================================================
-- Incoming transfers per private customer and calendar month, in two versions:
-- all incoming transfers (what TM-07 sums today) and incoming transfers
-- without those between the customer's own accounts (what Proposal A sums).
-- Assumption: "incoming transfers" means direction IN with status COMPLETED.
-- Returned and reversed transfers are left out. With this reading the rule
-- reproduces production's alerts exactly (see data quality section).
-- Assumption: the month is defined by booked_at.
-- Stored as a materialized view so the queries below run fast. Re-run this
-- section after any change to the data.
DROP MATERIALIZED VIEW IF EXISTS a_eval;
DROP MATERIALIZED VIEW IF EXISTS a_monthly;
CREATE MATERIALIZED VIEW a_monthly AS
SELECT t.customer_id,
       date_trunc('month', t.booked_at)::date                             AS month_start,
       SUM(t.amount_eur)                                                  AS in_total,
       COALESCE(SUM(t.amount_eur)
                FILTER (WHERE t.counterparty_id <> t.customer_id), 0)     AS in_excl_own
FROM tx_clean t
JOIN customers c USING (customer_id)
WHERE c.customer_type = 'PRIVATE'
  AND t.direction = 'IN'
  AND t.status = 'COMPLETED'
GROUP BY 1, 2;

-- One row per alert with its final status. monitoring_alerts is a status
-- history (NEW, IN_REVIEW, closed), so the latest row per alert is kept and
-- the outcome is taken from alert_statuses.
-- Statuses missing from alert_statuses get outcome 'NOT_IN_STATUS_TABLE'.
CREATE OR REPLACE VIEW alerts_final AS
SELECT DISTINCT ON (a.alert_id)
       a.alert_id, a.rule_code, a.customer_id, a.period_month, a.created_at,
       a.status                                    AS final_status,
       COALESCE(s.outcome, 'NOT_IN_STATUS_TABLE')  AS outcome
FROM monitoring_alerts a
LEFT JOIN alert_statuses s USING (status)
ORDER BY a.alert_id, a.status_changed_at DESC;

-- TM-07 evaluated for every private customer and month from Oct 2025 to
-- Sep 2026 (the months for which alerts exist and a 6-month baseline is
-- available). Baseline = sum of the 6 previous months' incoming transfers / 6,
-- so months with no activity count as zero. The baseline always includes
-- own-account transfers, as the proposal says it is calculated as today.
-- The actual production alert for the same customer and month is attached,
-- excluding the February 2026 alerts closed as technically incorrect.
CREATE MATERIALIZED VIEW a_eval AS
WITH base AS (
    SELECT cur.customer_id,
           cur.month_start,
           cur.in_total,
           cur.in_excl_own,
           COALESCE(SUM(prev.in_total), 0) / 6.0 AS baseline_avg
    FROM a_monthly cur
    LEFT JOIN a_monthly prev
           ON prev.customer_id = cur.customer_id
          AND prev.month_start >= cur.month_start - INTERVAL '6 months'
          AND prev.month_start <  cur.month_start
    WHERE cur.month_start >= DATE '2025-10-01'
    GROUP BY 1, 2, 3, 4
)
SELECT b.customer_id,
       to_char(b.month_start, 'YYYY-MM') AS period_month,
       b.in_total, b.in_excl_own, b.baseline_avg,
       -- TM-07 as specified today
       (b.in_total    >= 15000 AND b.in_total    >= 3 * b.baseline_avg) AS alert_today,
       -- Proposal A: threshold 25,000 and own-account transfers excluded
       (b.in_excl_own >= 25000 AND b.in_excl_own >= 3 * b.baseline_avg) AS alert_proposal_a,
       -- Proposal A split into its two parts, to see what each one does
       (b.in_total    >= 25000 AND b.in_total    >= 3 * b.baseline_avg) AS alert_threshold_only,
       (b.in_excl_own >= 15000 AND b.in_excl_own >= 3 * b.baseline_avg) AS alert_excl_own_only,
       -- A2: threshold lowered to 10,000, no other change
       (b.in_total    >= 10000 AND b.in_total    >= 3 * b.baseline_avg) AS alert_10k,
       f.alert_id, f.final_status, f.outcome
FROM base b
LEFT JOIN alerts_final f
       ON f.rule_code = 'TM-07'
      AND f.customer_id = b.customer_id
      AND f.period_month = to_char(b.month_start, 'YYYY-MM')
      AND f.final_status <> 'CLOSED_TECHNICALLY_INCORRECT';


-- =============================================================================
-- 2.2) ANSWERS TO A1 AND A2
-- =============================================================================

-- A1: monthly alert volume today, under Proposal A, under each half of the
-- proposal on its own, and at the 10,000 threshold (A2). The last row is the
-- 12-month total.
SELECT COALESCE(period_month, 'TOTAL')              AS period_month,
       COUNT(*) FILTER (WHERE alert_today)          AS today,
       COUNT(*) FILTER (WHERE alert_proposal_a)     AS proposal_a,
       COUNT(*) FILTER (WHERE alert_threshold_only) AS threshold_25k_only,
       COUNT(*) FILTER (WHERE alert_excl_own_only)  AS excl_own_only,
       COUNT(*) FILTER (WHERE alert_10k)            AS threshold_10k
FROM a_eval
GROUP BY ROLLUP (period_month)
ORDER BY period_month;

-- A1: what happens to today's alerts by analyst outcome - how many true
-- positives and false positives each variant keeps.
SELECT outcome,
       COUNT(*)                                     AS today,
       COUNT(*) FILTER (WHERE alert_proposal_a)     AS kept_proposal_a,
       COUNT(*) FILTER (WHERE alert_threshold_only) AS kept_threshold_25k_only,
       COUNT(*) FILTER (WHERE alert_excl_own_only)  AS kept_excl_own_only
FROM a_eval
WHERE alert_today
GROUP BY outcome
ORDER BY today DESC;

-- A1: does Proposal A create any alert that TM-07 does not raise today?
-- (Expected 0: both changes only make the rule stricter.)
SELECT COUNT(*) AS new_alerts_under_proposal_a
FROM a_eval
WHERE alert_proposal_a AND NOT alert_today;

-- A1: today's alerts by how much of the month's sum came from the customer's
-- own accounts, with true positives in each group.
SELECT CASE WHEN in_excl_own = in_total        THEN '1 no own-account money'
            WHEN in_excl_own >= 0.5 * in_total THEN '2 under half own-account'
            WHEN in_excl_own > 0               THEN '3 half or more own-account'
            ELSE '4 only own-account' END             AS own_account_share,
       COUNT(*)                                       AS alerts_today,
       COUNT(*) FILTER (WHERE outcome = 'TRUE_POSITIVE') AS true_positives
FROM a_eval
WHERE alert_today
GROUP BY 1 ORDER BY 1;

-- A1: today's alerts and true positives by size of the monthly sum. Shows how
-- many true positives sit between 15,000 and 25,000.
SELECT CASE WHEN in_total < 20000 THEN '1 15,000-19,999'
            WHEN in_total < 25000 THEN '2 20,000-24,999'
            WHEN in_total < 40000 THEN '3 25,000-39,999'
            ELSE '4 40,000 and above' END             AS monthly_sum,
       COUNT(*)                                       AS alerts_today,
       COUNT(*) FILTER (WHERE outcome = 'TRUE_POSITIVE') AS true_positives
FROM a_eval
WHERE alert_today
GROUP BY 1 ORDER BY 1;

-- A2: additional alerts if the threshold were 10,000 with no other change.
-- These customer-months were never alerted, so no analyst outcome exists.
SELECT COUNT(*)                    AS additional_alerts_12_months,
       ROUND(COUNT(*) / 12.0, 1)   AS additional_per_month,
       COUNT(DISTINCT customer_id) AS customers
FROM a_eval
WHERE alert_10k AND NOT alert_today;

-- A2: the closest evidence available - the true-positive rate of today's
-- lowest alerts (15,000-19,999). The 10,000-14,999 band has no outcomes.
SELECT COUNT(*)                                          AS alerts_15k_to_20k,
       COUNT(*) FILTER (WHERE outcome = 'TRUE_POSITIVE') AS true_positives,
       ROUND(100.0 * COUNT(*) FILTER (WHERE outcome = 'TRUE_POSITIVE') / COUNT(*), 1) AS tp_rate_pct
FROM a_eval
WHERE alert_today AND in_total < 20000;


-- =============================================================================
-- 2.3) DATA QUALITY QUESTIONS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Is there one row per alert?
-- Finding: no. TM-07 alerts have one row per status change (2 or 3 rows each),
-- so counting rows overstates TM-07 volume almost three times. Handled by
-- alerts_final. TM-02 and TM-11 have one row per alert.
-- -----------------------------------------------------------------------------

-- Rows per alert, by rule.
SELECT rule_code, rows_per_alert, COUNT(*) AS alerts
FROM (SELECT rule_code, alert_id, COUNT(*) AS rows_per_alert
      FROM monitoring_alerts
      GROUP BY 1, 2) g
GROUP BY 1, 2 ORDER BY 1, 2;

-- The status path each alert went through, by rule.
SELECT rule_code, status_path, COUNT(*) AS alerts
FROM (SELECT rule_code, alert_id,
             string_agg(status, ' > ' ORDER BY status_changed_at) AS status_path
      FROM monitoring_alerts
      GROUP BY 1, 2) g
GROUP BY 1, 2 ORDER BY 1, 3 DESC;

-- -----------------------------------------------------------------------------
-- Does every alert status have a meaning in alert_statuses?
-- Finding: no. CLOSED_TECHNICALLY_INCORRECT (400 alerts) is not in the table,
-- so an inner join would silently drop those alerts and a left join would
-- leave them without an outcome.
-- -----------------------------------------------------------------------------

-- Final alert statuses with their outcome from alert_statuses.
SELECT rule_code, final_status, outcome, COUNT(*) AS alerts
FROM alerts_final
GROUP BY 1, 2, 3 ORDER BY 1, 4 DESC;

-- -----------------------------------------------------------------------------
-- Is TM-07's alert volume stable from month to month?
-- Finding: about 100 alerts a month, except February 2026 with 512. The extra
-- 400 were all closed as technically incorrect two days later, and none of
-- them meets the rule's conditions. They are excluded from the baseline.
-- -----------------------------------------------------------------------------

-- TM-07 alerts per evaluated month, split by final status.
SELECT period_month,
       COUNT(*)                                                               AS alerts,
       COUNT(*) FILTER (WHERE final_status = 'CLOSED_TECHNICALLY_INCORRECT') AS technically_incorrect,
       COUNT(*) FILTER (WHERE outcome = 'TRUE_POSITIVE')                      AS true_positives,
       COUNT(*) FILTER (WHERE outcome = 'FALSE_POSITIVE')                     AS false_positives
FROM alerts_final
WHERE rule_code = 'TM-07'
GROUP BY 1 ORDER BY 1;

-- The technically incorrect alerts measured against the rule's conditions:
-- how many reach 15,000, and how many reach 3x the baseline?
SELECT COUNT(*)                                                      AS alerts,
       COUNT(*) FILTER (WHERE e.in_total >= 15000)                   AS reach_15k,
       COUNT(*) FILTER (WHERE e.in_total >= 3 * e.baseline_avg)      AS reach_3x_baseline,
       ROUND(MAX(e.in_total))                                        AS highest_monthly_sum
FROM alerts_final f
LEFT JOIN a_eval e USING (customer_id, period_month)
WHERE f.rule_code = 'TM-07'
  AND f.final_status = 'CLOSED_TECHNICALLY_INCORRECT';

-- -----------------------------------------------------------------------------
-- Does the rule as specified reproduce the alerts production raised?
-- Finding: yes, exactly. Every valid production alert is reproduced and the
-- rebuilt rule raises no alert that production did not. This confirms the
-- reading of "incoming transfers" as completed transfers and that production
-- ran on data without the reloaded duplicates.
-- -----------------------------------------------------------------------------

-- Rebuilt rule compared with production alerts, per customer and month.
SELECT COUNT(*) FILTER (WHERE e.alert_today AND e.alert_id IS NOT NULL) AS in_both,
       COUNT(*) FILTER (WHERE e.alert_today AND e.alert_id IS NULL)     AS only_rebuilt,
       COUNT(*) FILTER (WHERE NOT e.alert_today AND e.alert_id IS NOT NULL) AS only_production
FROM a_eval e;

-- Valid production TM-07 alerts with no incoming transfers at all in that
-- month (these would not appear in a_eval). Expected 0.
SELECT COUNT(*) AS production_alerts_without_incoming
FROM alerts_final f
LEFT JOIN a_eval e USING (customer_id, period_month)
WHERE f.rule_code = 'TM-07'
  AND f.final_status <> 'CLOSED_TECHNICALLY_INCORRECT'
  AND e.customer_id IS NULL;

-- -----------------------------------------------------------------------------
-- What would the reloaded duplicate transactions do to TM-07?
-- Finding: run on the raw transactions table, the rule would raise more alerts
-- than production did, because a duplicated transfer can lift a customer over
-- the 15,000 threshold. Any analysis on the raw table overstates volume.
-- -----------------------------------------------------------------------------

-- TM-07 as specified, evaluated on the raw table with duplicates left in.
WITH monthly_raw AS (
    SELECT t.customer_id,
           date_trunc('month', t.booked_at)::date AS month_start,
           SUM(t.amount_eur)                      AS in_total
    FROM transactions t
    JOIN customers c USING (customer_id)
    WHERE c.customer_type = 'PRIVATE' AND t.direction = 'IN' AND t.status = 'COMPLETED'
    GROUP BY 1, 2
), base AS (
    SELECT cur.customer_id, cur.month_start, cur.in_total,
           COALESCE(SUM(prev.in_total), 0) / 6.0 AS baseline_avg
    FROM monthly_raw cur
    LEFT JOIN monthly_raw prev
           ON prev.customer_id = cur.customer_id
          AND prev.month_start >= cur.month_start - INTERVAL '6 months'
          AND prev.month_start <  cur.month_start
    WHERE cur.month_start >= DATE '2025-10-01'
    GROUP BY 1, 2, 3
)
SELECT COUNT(*) AS alerts_on_raw_data_12_months
FROM base
WHERE in_total >= 15000 AND in_total >= 3 * baseline_avg;

-- -----------------------------------------------------------------------------
-- How much incoming value is not COMPLETED?
-- Finding: returned and reversed transfers are a small share of rows but a
-- visible share of value. They are excluded from the rule's sums.
-- -----------------------------------------------------------------------------

-- Incoming transfers by status.
SELECT status, COUNT(*) AS transfers, ROUND(SUM(amount_eur)) AS eur
FROM tx_clean
WHERE direction = 'IN'
GROUP BY status ORDER BY transfers DESC;


-- =============================================================================
-- 3) PROPOSAL B: customer risk model v4 (question B1)
-- 3.1) SOLUTION
-- =============================================================================
-- Original version of the v3.2 score view. It read risk_factor_scores as
-- delivered. Replaced because the 30 Sept 2026 scores are in the table twice,
-- which doubled every customer's total (see "Are factor scores loaded once?").
--CREATE OR REPLACE VIEW b_v32 AS
--SELECT s.customer_id,
--       SUM(s.score * f.weight)                                AS total_v32,
--       MAX(s.score) FILTER (WHERE s.factor_code = 'F06')      AS f06_score
--FROM risk_factor_scores s
--JOIN risk_factors f USING (factor_code)
--WHERE s.score_date = DATE '2026-09-30'
--GROUP BY s.customer_id;

-- v3.2 total score per customer at 30 Sept 2026: factor score x weight, summed
-- over F01-F08. Also keeps the F06 score, because v4 changes that weight.
-- The 30 Sept batch was loaded twice (02:00 and 08:30 on 1 Oct) with identical
-- scores, so one row per customer and factor is kept (the latest load).
CREATE OR REPLACE VIEW b_v32 AS
WITH dedup AS (
    SELECT DISTINCT ON (customer_id, score_date, factor_code)
           customer_id, score_date, factor_code, score
    FROM risk_factor_scores
    WHERE score_date = DATE '2026-09-30'
    ORDER BY customer_id, score_date, factor_code, loaded_at DESC
)
SELECT d.customer_id,
       SUM(d.score * f.weight)                           AS total_v32,
       MAX(d.score) FILTER (WHERE d.factor_code = 'F06') AS f06_score
FROM dedup d
JOIN risk_factors f USING (factor_code)
GROUP BY d.customer_id;

-- Original version of the F09 view. It read the transactions table directly.
-- Replaced because duplicated transactions inflated the sums (see "Is each
-- transaction in the table once?").
--CREATE OR REPLACE VIEW b_f09 AS
--SELECT t.customer_id,
--       SUM(t.amount_eur)                                           AS out_total,
--       SUM(t.amount_eur) FILTER (WHERE h.country IS NOT NULL)      AS out_high_risk,
--       COALESCE(SUM(t.amount_eur) FILTER (WHERE h.country IS NOT NULL), 0)
--           / NULLIF(SUM(t.amount_eur), 0)                          AS hr_share
--FROM transactions t
--LEFT JOIN banks b               ON b.bic = t.counterparty_bank_bic
--LEFT JOIN high_risk_countries h ON h.country = COALESCE(t.counterparty_country, b.country)
--WHERE t.direction = 'OUT'
--  AND t.status = 'COMPLETED'
--  AND t.counterparty_id <> t.customer_id
--  AND t.booked_at >= TIMESTAMP '2026-04-01'
--  AND t.booked_at <  TIMESTAMP '2026-10-01'
--GROUP BY t.customer_id;

-- New factor F09 "High-risk country exposure": per customer, the share of the
-- value of completed outgoing transfers booked 1 Apr - 30 Sep 2026 that went
-- to a high-risk country. Transfers between the customer's own accounts are
-- excluded.
-- Assumption: the destination is the country given in the payment and, where
-- that is empty (almost always), the country of the counterparty's bank.
-- Assumption: the period is defined by booked_at.
-- Limitation: transfers with no bank code count as not high-risk.
CREATE OR REPLACE VIEW b_f09 AS
SELECT t.customer_id,
       SUM(t.amount_eur)                                           AS out_total,
       SUM(t.amount_eur) FILTER (WHERE h.country IS NOT NULL)      AS out_high_risk,
       COALESCE(SUM(t.amount_eur) FILTER (WHERE h.country IS NOT NULL), 0)
           / NULLIF(SUM(t.amount_eur), 0)                          AS hr_share
FROM tx_clean t
LEFT JOIN banks b               ON b.bic = t.counterparty_bank_bic
LEFT JOIN high_risk_countries h ON h.country = COALESCE(t.counterparty_country, b.country)
WHERE t.direction = 'OUT'
  AND t.status = 'COMPLETED'
  AND t.counterparty_id <> t.customer_id
  AND t.booked_at >= TIMESTAMP '2026-04-01'
  AND t.booked_at <  TIMESTAMP '2026-10-01'
GROUP BY t.customer_id;

-- v3.2 and v4 side by side for every scored customer.
-- F09 score: 0 below 10%, 1 from 10%, 2 from 25%, 3 from 50%. Customers with
-- no qualifying outgoing transfers get 0.
-- v4 total = v3.2 total + F06 score x (3.0 - 2.4) + F09 score x 1.5.
-- Bands: LOW below 5, MEDIUM below 9, MEDIUM-HIGH below 12, HIGH from 12.
CREATE OR REPLACE VIEW b_compare AS
WITH scored AS (
    SELECT v.customer_id,
           v.total_v32,
           v.f06_score,
           COALESCE(f.hr_share, 0) AS hr_share,
           CASE WHEN COALESCE(f.hr_share, 0) >= 0.50 THEN 3
                WHEN COALESCE(f.hr_share, 0) >= 0.25 THEN 2
                WHEN COALESCE(f.hr_share, 0) >= 0.10 THEN 1
                ELSE 0 END         AS f09_score
    FROM b_v32 v
    LEFT JOIN b_f09 f USING (customer_id)
), totals AS (
    SELECT *,
           total_v32 + COALESCE(f06_score, 0) * (3.0 - 2.4) + f09_score * 1.5 AS total_v4
    FROM scored
)
SELECT *,
       CASE WHEN total_v32 >= 12 THEN 'HIGH' WHEN total_v32 >= 9 THEN 'MEDIUM-HIGH'
            WHEN total_v32 >= 5  THEN 'MEDIUM' ELSE 'LOW' END AS band_v32,
       CASE WHEN total_v4  >= 12 THEN 'HIGH' WHEN total_v4  >= 9 THEN 'MEDIUM-HIGH'
            WHEN total_v4  >= 5  THEN 'MEDIUM' ELSE 'LOW' END AS band_v4
FROM totals;

-- Inspect the three views row by row.
SELECT * FROM b_v32;
SELECT * FROM b_f09;
SELECT * FROM b_compare;


-- =============================================================================
-- 3.2) ANSWERS TO B1
-- =============================================================================

-- B1: how many customers change band under v4, and how many newly become HIGH?
SELECT COUNT(*)                                                        AS customers_scored,
       COUNT(*) FILTER (WHERE band_v32 <> band_v4)                     AS changed_band,
       COUNT(*) FILTER (WHERE band_v4 = 'HIGH' AND band_v32 <> 'HIGH') AS newly_high
FROM b_compare;

-- B1: migration matrix - from which v3.2 band to which v4 band.
SELECT band_v32, band_v4, COUNT(*) AS customers
FROM b_compare
GROUP BY band_v32, band_v4
ORDER BY band_v32, band_v4;

-- B1: which of the two changes moves the newly HIGH customers - the new
-- factor F09, the higher F06 weight, or both together?
SELECT COUNT(*) FILTER (WHERE f09_score > 0 AND COALESCE(f06_score,0) = 0) AS only_f09,
       COUNT(*) FILTER (WHERE f09_score = 0 AND COALESCE(f06_score,0) > 0) AS only_f06,
       COUNT(*) FILTER (WHERE f09_score > 0 AND COALESCE(f06_score,0) > 0) AS both
FROM b_compare
WHERE band_v4 = 'HIGH' AND band_v32 <> 'HIGH';


-- =============================================================================
-- 3.3) DATA QUALITY QUESTIONS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Are factor scores loaded once per customer, factor and month-end?
-- Finding: 31 Aug is clean. 30 Sept is in the table twice (two load batches,
-- identical scores). Handled by the deduplication in b_v32.
-- -----------------------------------------------------------------------------

-- Rows compared with distinct customer-factor pairs, per month-end.
SELECT score_date,
       COUNT(*)                                   AS row_count,
       COUNT(DISTINCT customer_id)                AS customers,
       COUNT(DISTINCT (customer_id, factor_code)) AS distinct_keys,
       COUNT(*) - COUNT(DISTINCT (customer_id, factor_code)) AS extra_rows
FROM risk_factor_scores
GROUP BY score_date
ORDER BY score_date;

-- How many copies each customer-factor pair has, and whether the copies
-- disagree on the score or only on the load time.
SELECT score_date, copies,
       COUNT(*)                          AS key_groups,
       SUM((distinct_scores > 1)::int)   AS conflicting_scores,
       SUM((distinct_loads  > 1)::int)   AS different_loaded_at
FROM (
    SELECT score_date, customer_id, factor_code,
           COUNT(*)                  AS copies,
           COUNT(DISTINCT score)     AS distinct_scores,
           COUNT(DISTINCT loaded_at) AS distinct_loads
    FROM risk_factor_scores
    GROUP BY 1, 2, 3
) g
GROUP BY score_date, copies
ORDER BY 1, 2;

-- Load batches per month-end: shows the second load of the 30 Sept scores.
SELECT score_date, loaded_at, COUNT(*) AS row_count
FROM risk_factor_scores
GROUP BY 1, 2
ORDER BY 1, 2;

-- -----------------------------------------------------------------------------
-- Does the recalculated v3.2 score match what production recorded?
-- Finding: after deduplication all totals equal risk_snapshot for 30 Sept, and
-- no customer is missing on either side. The v3.2 baseline is reliable.
-- -----------------------------------------------------------------------------

-- Recalculated v3.2 totals compared with the production snapshot.
SELECT COUNT(*) FILTER (WHERE s.customer_id IS NULL)        AS only_in_calculation,
       COUNT(*) FILTER (WHERE v.customer_id IS NULL)        AS only_in_snapshot,
       COUNT(*) FILTER (WHERE s.total_score =  v.total_v32) AS equal_totals,
       COUNT(*) FILTER (WHERE s.total_score <> v.total_v32) AS different_totals
FROM b_v32 v
FULL JOIN (SELECT * FROM risk_snapshot
           WHERE snapshot_date = DATE '2026-09-30') s USING (customer_id);

-- -----------------------------------------------------------------------------
-- Where exactly do the risk bands start and end?
-- The brief lists whole numbers (0-4, 5-8, 9-11, 12+) but totals are decimals.
-- Finding: production uses LOW up to 4.9, MEDIUM 5.0-8.9, MEDIUM-HIGH 9.0-11.9,
-- HIGH from 12.0. The band rules in b_compare follow this.
-- -----------------------------------------------------------------------------

-- Lowest and highest total score in each band, as recorded by production.
SELECT risk_band, MIN(total_score) AS lowest, MAX(total_score) AS highest,
       COUNT(*) AS snapshot_rows
FROM risk_snapshot
GROUP BY risk_band
ORDER BY lowest;

-- -----------------------------------------------------------------------------
-- Do we know which country an outgoing transfer went to?
-- Finding: counterparty_country is almost always empty, so the bank's country
-- is used. About a third of in-scope value goes to e-money institutions and
-- about 8% has no bank code, so the real destination is unknown for those.
-- This cannot be fixed in the query and is reported as a limitation of F09.
-- -----------------------------------------------------------------------------

-- How often the payment country and the bank code are filled in, by direction.
SELECT direction,
       COUNT(*)                     AS transactions,
       COUNT(counterparty_country)  AS country_filled,
       COUNT(counterparty_bank_bic) AS bic_filled,
       COUNT(*) FILTER (WHERE counterparty_country IS NULL
                          AND counterparty_bank_bic IS NULL) AS neither
FROM transactions
GROUP BY direction;

-- In-scope outgoing transfers by where the destination information comes
-- from: a bank, an e-money institution, or no bank code at all.
SELECT CASE WHEN t.counterparty_bank_bic IS NULL THEN 'no BIC'
            ELSE b.institution_type END              AS destination_source,
       (h.country IS NOT NULL)                       AS bank_country_high_risk,
       COUNT(*)                                      AS transfers,
       COUNT(DISTINCT t.customer_id)                 AS customers,
       ROUND(SUM(t.amount_eur))                      AS eur,
       ROUND(100 * SUM(t.amount_eur) / SUM(SUM(t.amount_eur)) OVER (), 1) AS pct_of_value
FROM tx_clean t
LEFT JOIN banks b               ON b.bic = t.counterparty_bank_bic
LEFT JOIN high_risk_countries h ON h.country = b.country
WHERE t.direction = 'OUT' AND t.status = 'COMPLETED'
  AND t.counterparty_id <> t.customer_id
  AND t.booked_at >= TIMESTAMP '2026-04-01' AND t.booked_at < TIMESTAMP '2026-10-01'
GROUP BY 1, 2
ORDER BY 1, 2;

-- Outgoing transfers without a bank code per month: a one-off or permanent?
SELECT date_trunc('month', booked_at)::date AS month,
       COUNT(*)                                              AS outgoing,
       COUNT(*) FILTER (WHERE counterparty_bank_bic IS NULL) AS without_bic
FROM tx_clean
WHERE direction = 'OUT'
GROUP BY 1 ORDER BY 1;

-- Worst case for B1: if every in-scope transfer without a bank code had gone
-- to a high-risk country, how many customers would newly become HIGH?
WITH f09_worst AS (
    SELECT t.customer_id,
           COALESCE(SUM(t.amount_eur) FILTER (WHERE h.country IS NOT NULL
                                                 OR t.counterparty_bank_bic IS NULL), 0)
               / NULLIF(SUM(t.amount_eur), 0) AS hr_share
    FROM tx_clean t
    LEFT JOIN banks b               ON b.bic = t.counterparty_bank_bic
    LEFT JOIN high_risk_countries h ON h.country = COALESCE(t.counterparty_country, b.country)
    WHERE t.direction = 'OUT' AND t.status = 'COMPLETED'
      AND t.counterparty_id <> t.customer_id
      AND t.booked_at >= TIMESTAMP '2026-04-01' AND t.booked_at < TIMESTAMP '2026-10-01'
    GROUP BY t.customer_id
)
SELECT COUNT(*) AS newly_high_worst_case
FROM b_v32 v
LEFT JOIN f09_worst f USING (customer_id)
WHERE v.total_v32 < 12
  AND v.total_v32 + COALESCE(v.f06_score, 0) * (3.0 - 2.4)
      + 1.5 * CASE WHEN COALESCE(f.hr_share, 0) >= 0.50 THEN 3
                   WHEN COALESCE(f.hr_share, 0) >= 0.25 THEN 2
                   WHEN COALESCE(f.hr_share, 0) >= 0.10 THEN 1
                   ELSE 0 END >= 12;

-- -----------------------------------------------------------------------------
-- Is each transaction in the table once?
-- Finding: about 25,000 transactions appear twice, every month, identical
-- except for load_date. Handled by tx_clean.
-- -----------------------------------------------------------------------------

-- How many copies each transaction key (transaction_id, counterparty_id) has.
SELECT copies, COUNT(*) AS key_groups
FROM (SELECT COUNT(*) AS copies
      FROM transactions
      GROUP BY transaction_id, counterparty_id) g
GROUP BY copies ORDER BY copies;

-- Within duplicated transactions, which columns differ between the copies?
SELECT COUNT(*)                 AS duplicated_keys,
       SUM((n_amount > 1)::int) AS differ_amount,
       SUM((n_status > 1)::int) AS differ_status,
       SUM((n_booked > 1)::int) AS differ_booked_at,
       SUM((n_load   > 1)::int) AS differ_load_date
FROM (SELECT COUNT(DISTINCT amount_eur) AS n_amount,
             COUNT(DISTINCT status)     AS n_status,
             COUNT(DISTINCT booked_at)  AS n_booked,
             COUNT(DISTINCT load_date)  AS n_load
      FROM transactions
      GROUP BY transaction_id, counterparty_id
      HAVING COUNT(*) > 1) g;

-- Duplicated transactions per booking month: a one-off or a standing fault?
SELECT date_trunc('month', booked_at)::date AS month, COUNT(*) AS duplicated
FROM (SELECT MIN(booked_at) AS booked_at
      FROM transactions
      GROUP BY transaction_id, counterparty_id
      HAVING COUNT(*) > 1) g
GROUP BY 1 ORDER BY 1;

-- -----------------------------------------------------------------------------
-- Is the April-September period complete, and does the choice of date matter?
-- Finding: data runs to 30 Sept 23:59 with normal volumes. Few transfers are
-- booked in one month and exported in the next, and using exported_at gives
-- the same F09 scores. booked_at is kept.
-- -----------------------------------------------------------------------------

-- First and last booking, last export and last load in the data.
SELECT MIN(booked_at) AS first_booked, MAX(booked_at) AS last_booked,
       MAX(exported_at) AS last_exported, MAX(load_date) AS last_load
FROM tx_clean;

-- Transfers booked in one month and exported in the next.
SELECT to_char(booked_at, 'YYYY-MM')   AS booked_month,
       to_char(exported_at, 'YYYY-MM') AS exported_month,
       COUNT(*) AS transfers, ROUND(SUM(amount_eur)) AS eur
FROM tx_clean
WHERE to_char(booked_at, 'YYYY-MM') <> to_char(exported_at, 'YYYY-MM')
GROUP BY 1, 2 ORDER BY 1;