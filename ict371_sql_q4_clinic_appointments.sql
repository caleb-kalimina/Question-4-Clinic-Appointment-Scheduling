-- ============================================================================
-- ICT371 Advanced Database
-- Question 4: Clinic Appointment Scheduling (50 marks)
-- PostgreSQL Implementation
-- ============================================================================

BEGIN;

DROP VIEW IF EXISTS v_today_appointments CASCADE;
DROP TABLE IF EXISTS clinic_summary CASCADE;
DROP TABLE IF EXISTS appointments CASCADE;
DROP TABLE IF EXISTS doctors CASCADE;
DROP TABLE IF EXISTS patients CASCADE;

-- ----------------------------------------------------------------------------
-- (a) Database and seed data [6 marks]
-- ----------------------------------------------------------------------------
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(120) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(120) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INTEGER NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL CHECK (slot_time IN ('09:00:00', '10:00:00', '11:00:00', '12:00:00')),
    status          VARCHAR(15) NOT NULL CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date   DATE PRIMARY KEY,
    booked_count   INTEGER NOT NULL CHECK (booked_count >= 0),
    attended_count INTEGER NOT NULL CHECK (attended_count >= 0),
    cancelled_count INTEGER NOT NULL CHECK (cancelled_count >= 0)
);

-- ----------------------------------------------------------------------------
-- (b) Function: fn_daily_load(p_doctor_id, p_day) [6 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(
    p_doctor_id INTEGER,
    p_day       DATE
) RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_load INTEGER;
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Appointment day (p_day) cannot be NULL.';
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_load
      FROM appointments
     WHERE doctor_id = p_doctor_id
       AND appointment_day = p_day
       AND status <> 'CANCELLED';

    RETURN v_load;
END;
$$;

-- ----------------------------------------------------------------------------
-- (c) Procedure: pr_book_appointment(p_patient_id, p_doctor_id, p_day, p_slot) [8 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INTEGER,
    p_doctor_id  INTEGER,
    p_day        DATE,
    p_slot       TIME
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Invalid appointment date (%): cannot book in the past.', p_day;
    END IF;

    IF p_slot IS NULL OR p_slot NOT IN ('09:00:00'::TIME, '10:00:00'::TIME, '11:00:00'::TIME, '12:00:00'::TIME) THEN
        RAISE EXCEPTION 'Unsupported slot (%): allowed slots are 09:00, 10:00, 11:00, 12:00.', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- ----------------------------------------------------------------------------
-- (d) Trigger: BEFORE INSERT OR UPDATE row trigger on appointments [8 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_appointments_no_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        -- Serialize concurrent bookings for the same doctor and day
        PERFORM 1 FROM doctors WHERE doctor_id = NEW.doctor_id FOR UPDATE;

        IF EXISTS (
            SELECT 1
              FROM appointments a
             WHERE a.doctor_id = NEW.doctor_id
               AND a.appointment_day = NEW.appointment_day
               AND a.slot_time = NEW.slot_time
               AND a.status <> 'CANCELLED'
               AND (TG_OP = 'INSERT' OR a.appointment_id <> OLD.appointment_id)
        ) THEN
            RAISE EXCEPTION 'Slot clash: doctor % already has a non-cancelled appointment on % at %.',
                NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_no_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_appointments_no_clash();

-- ----------------------------------------------------------------------------
-- (a cont.) Seed 3 patients, 3 doctors, and 6 valid appointments
-- ----------------------------------------------------------------------------
INSERT INTO patients (full_name) VALUES
    ('Musonda Chileshe'),
    ('Agness Phiri'),
    ('Peter Mumba');

INSERT INTO doctors (full_name) VALUES
    ('Dr. Kapambwe Nsofwa'),
    ('Dr. Ruth Lungu'),
    ('Dr. Isaac Simukonda');

CALL pr_book_appointment(1, 1, CURRENT_DATE,     '09:00:00');
CALL pr_book_appointment(2, 1, CURRENT_DATE,     '10:00:00');
CALL pr_book_appointment(3, 2, CURRENT_DATE,     '09:00:00');
CALL pr_book_appointment(1, 2, CURRENT_DATE + 1, '11:00:00');
CALL pr_book_appointment(2, 3, CURRENT_DATE + 1, '12:00:00');
CALL pr_book_appointment(3, 1, CURRENT_DATE + 2, '09:00:00');

-- ----------------------------------------------------------------------------
-- (e) View: v_today_appointments [5 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT
    p.full_name AS patient_name,
    d.full_name AS doctor_name,
    a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors d  ON d.doctor_id = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED'
ORDER BY a.slot_time ASC, d.full_name ASC;

SELECT * FROM v_today_appointments;

-- ----------------------------------------------------------------------------
-- (f) Index & EXPLAIN [5 marks]
-- Justification: A non-unique composite B-tree index on (appointment_day, doctor_id)
-- allows filtering all appointments on a given date and narrowing directly to
-- a specific doctor's schedule without a full table scan.
-- ----------------------------------------------------------------------------
CREATE INDEX idx_appointments_day_doctor
    ON appointments (appointment_day, doctor_id);

EXPLAIN
SELECT appointment_id, patient_id, doctor_id, appointment_day, slot_time, status
  FROM appointments
 WHERE appointment_day = CURRENT_DATE
   AND doctor_id = 1;

-- ----------------------------------------------------------------------------
-- (g) Scheduled job: pr_refresh_clinic_summary(p_day) & pg_cron [6 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_booked    INTEGER;
    v_attended  INTEGER;
    v_cancelled INTEGER;
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Summary date (p_day) cannot be NULL.';
    END IF;

    SELECT COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
      INTO v_booked, v_attended, v_cancelled
      FROM appointments
     WHERE appointment_day = p_day;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    VALUES (p_day, v_booked, v_attended, v_cancelled)
    ON CONFLICT (summary_date) DO UPDATE
        SET booked_count    = EXCLUDED.booked_count,
            attended_count  = EXCLUDED.attended_count,
            cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);

COMMIT;

-- Schedule daily at 01:00 for the previous day
SELECT cron.schedule(
    'clinic_daily_summary_refresh',
    '0 1 * * *',
    $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);$$
);
