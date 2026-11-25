-- =====================================================================
-- ICT371 Advanced Database | Student No: 202407871
-- QUESTION 3: Library Returns and Overdue Fines  (50 marks)
-- Run with:  psql -d yourdb -f ICT371_202407871_Q3_Library.sql
-- Objects live in schema q3_library; the script can be re-run safely.
-- =====================================================================
DROP SCHEMA IF EXISTS q3_library CASCADE;
CREATE SCHEMA q3_library;
SET search_path TO q3_library, public;

-- ---------------------------------------------------------------------
-- (a) DATABASE AND SEED DATA [6]
-- ---------------------------------------------------------------------
CREATE TABLE books (
    book_id  SERIAL       PRIMARY KEY,
    title    VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id        SERIAL        PRIMARY KEY,
    book_id        INTEGER       NOT NULL REFERENCES books(book_id),
    borrower_name  VARCHAR(100)  NOT NULL,
    borrowed_on    DATE          NOT NULL,
    due_on         DATE          NOT NULL,
    returned_on    DATE          NULL,
    fine_amount    NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT chk_due_after_borrowed CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id          SERIAL     PRIMARY KEY,
    loan_id           INTEGER    NOT NULL REFERENCES loans(loan_id),
    old_returned_on   DATE       NULL,
    new_returned_on   DATE       NULL,
    changed_at        TIMESTAMP  NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date  DATE          PRIMARY KEY,
    overdue_count  INTEGER       NOT NULL,
    total_fine     NUMERIC(12,2) NOT NULL
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Introduction to Algorithms'),
    ('Clean Code');

-- Six loans (all inserted unreturned; the three returned ones are closed
-- later through pr_return_loan so the fine and audit are produced properly).
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Alice Tembo',   CURRENT_DATE - 20, CURRENT_DATE - 6),   -- 1 OPEN OVERDUE (6 days -> K12 today)
    (2, 'Bob Zulu',      CURRENT_DATE - 5,  CURRENT_DATE + 9),   -- 2 ON-TIME, still open, not yet due
    (1, 'Chanda Mwila',  CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 3 will be returned LATE (K12)
    (2, 'Dalitso Nkhoma',CURRENT_DATE - 25, CURRENT_DATE - 11),  -- 4 will be returned EARLY (K0)
    (3, 'Esther Daka',   CURRENT_DATE - 18, CURRENT_DATE - 4),   -- 5 will be returned ON the due date (K0)
    (3, 'Felix Sakala',  CURRENT_DATE - 12, CURRENT_DATE - 3);   -- 6 OPEN OVERDUE (3 days -> K6 today)

-- ---------------------------------------------------------------------
-- (b) FUNCTION fn_loan_fine [6]
-- fine = K2 x overdue days, minimum 0.
-- end date = earlier of p_as_of and returned_on (if returned).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_returned
    FROM   loans
    WHERE  loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    -- A returned loan stops accumulating fines
    IF v_returned IS NOT NULL THEN
        v_end := LEAST(p_as_of, v_returned);
    ELSE
        v_end := p_as_of;
    END IF;

    -- v_end - v_due is a whole number of days; due date itself = 0 days
    RETURN 2 * GREATEST(v_end - v_due, 0);
END;
$$;

-- ---------------------------------------------------------------------
-- (c) PROCEDURE pr_return_loan [8]
-- Return date and final fine are stored in ONE UPDATE (together).
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
    v_fine     NUMERIC(10,2);
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date must not be NULL';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM   loans
    WHERE  loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrowed date %', p_returned_on, v_borrowed;
    END IF;

    -- returned_on is still NULL here, so fn_loan_fine uses p_returned_on as the end date
    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans
    SET    returned_on = p_returned_on,
           fine_amount = v_fine
    WHERE  loan_id = p_loan_id;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) TRIGGER AFTER UPDATE [8]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_loan_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_returned_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)     -- NULL-safe "has changed"
EXECUTE FUNCTION trg_fn_loan_audit();

-- Close the three returned loans through the procedure
CALL pr_return_loan(3, CURRENT_DATE - 10);   -- 6 days late  -> K12
CALL pr_return_loan(4, CURRENT_DATE - 13);   -- early        -> K0
CALL pr_return_loan(5, CURRENT_DATE - 4);    -- on due date  -> K0

-- ---------------------------------------------------------------------
-- (e) VIEW v_overdue_loans [5]
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id,
       b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM   loans l
JOIN   books b ON b.book_id = l.book_id
WHERE  l.returned_on IS NULL
  AND  l.due_on < CURRENT_DATE;

-- ---------------------------------------------------------------------
-- (f) INDEX [5]  Partial index: only UNRETURNED loans are indexed, so it
-- is small and exactly matches "book X's unreturned loans".
-- ---------------------------------------------------------------------
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;

-- ---------------------------------------------------------------------
-- (g) SCHEDULED JOB [6]
-- ASSUMPTION: "overdue_count" counts loans unreturned as of p_as_of that
-- are past their due date (due_on < p_as_of). Remove that predicate if
-- your lecturer wants every unreturned loan counted.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM   loans
    WHERE  (returned_on IS NULL OR returned_on > p_as_of)   -- still unreturned on that date
      AND  due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
        SET overdue_count = EXCLUDED.overdue_count,
            total_fine    = EXCLUDED.total_fine;
END;
$$;


-- Safe scheduling: runs only if pg_cron is available on this server.
-- If it is not installed you will just see a NOTICE and the rest of the script still works.
DO $do$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.schedule('q3_refresh_overdue', '10 0 * * *', $cmd$CALL q3_library.pr_refresh_overdue(CURRENT_DATE)$cmd$);
        RAISE NOTICE 'Job q3_refresh_overdue scheduled: 10 0 * * *';
    ELSE
        RAISE NOTICE 'pg_cron is not installed on this server - job NOT scheduled. Schedule used: 10 0 * * *';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Could not schedule job (q3_refresh_overdue): %', SQLERRM;
END
$do$;

-- Inspect job / history (uncomment where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q3_refresh_overdue';
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;

-- =====================================================================
-- TESTS / EVIDENCE
-- =====================================================================
SELECT '--- (a) Data ---' AS section;
SELECT * FROM loans ORDER BY loan_id;

SELECT '--- (b) Function ---' AS section;
SELECT loan_id, fn_loan_fine(loan_id, CURRENT_DATE) AS fine_today FROM loans ORDER BY loan_id;  -- 12, 0, 12, 0, 0, 6
SELECT fn_loan_fine(3, CURRENT_DATE + 100) AS returned_loan_stops_accumulating;                  -- still 12
DO $$ BEGIN PERFORM fn_loan_fine(999, CURRENT_DATE);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (unknown loan): %', SQLERRM; END $$;

SELECT '--- (c) Procedure: rejected cases ---' AS section;
DO $$ BEGIN CALL pr_return_loan(999, CURRENT_DATE);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (unknown): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(3, CURRENT_DATE);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (already returned): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(1, CURRENT_DATE - 100);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (before borrowed_on): %', SQLERRM; END $$;
SELECT loan_id, returned_on, fine_amount FROM loans ORDER BY loan_id;

SELECT '--- (d) Trigger: 3 audit rows; no row when the date is unchanged ---' AS section;
SELECT * FROM loan_audit ORDER BY audit_id;
UPDATE loans SET returned_on = returned_on WHERE loan_id = 3;   -- same value -> no audit
UPDATE loans SET borrower_name = 'Chanda M. Mwila' WHERE loan_id = 3;
SELECT COUNT(*) AS audit_rows_still_3 FROM loan_audit;

SELECT '--- (e) View ---' AS section;
SELECT * FROM v_overdue_loans ORDER BY loan_id;                 -- loans 1 and 6

SELECT '--- (f) EXPLAIN ---' AS section;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;
RESET enable_seqscan;

SELECT '--- (g) Run twice: same snapshot_date is replaced ---' AS section;
CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM overdue_summary;                                  -- count 2, fine 18
CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM overdue_summary;                                  -- identical, one row
