
-- Создаём схему DM
CREATE SCHEMA IF NOT EXISTS dm;

-- Витрина оборотов
CREATE TABLE IF NOT EXISTS dm.dm_account_turnover_f (
    on_date         DATE NOT NULL,
    account_rk      BIGINT NOT NULL,
    credit_amount   NUMERIC(23,8),
    credit_amount_rub NUMERIC(23,8),
    debet_amount    NUMERIC(23,8),
    debet_amount_rub NUMERIC(23,8),
    PRIMARY KEY (on_date, account_rk)
);

-- Витрина остатков
CREATE TABLE IF NOT EXISTS dm.dm_account_balance_f (
    on_date         DATE NOT NULL,
    account_rk      BIGINT NOT NULL,
    balance_out     NUMERIC(23,8),
    balance_out_rub NUMERIC(23,8),
    PRIMARY KEY (on_date, account_rk)
);


-- Процедура расчета оборотов 

CREATE OR REPLACE FUNCTION ds.fill_account_turnover_f(i_OnDate DATE)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_time TIMESTAMP;
    v_end_time   TIMESTAMP;
    v_rows       INT;
BEGIN
    v_start_time := clock_timestamp();
    
    INSERT INTO logs.etl_log (process_name, start_time, status, message)
    VALUES ('FILL_TURNOVER', v_start_time, 'STARTED', 'i_OnDate = ' || i_OnDate::TEXT);
    
    DELETE FROM dm.dm_account_turnover_f WHERE on_date = i_OnDate;
   
    INSERT INTO dm.dm_account_turnover_f (on_date, account_rk, credit_amount, credit_amount_rub, debet_amount, debet_amount_rub)
    SELECT
        i_OnDate,
        act.account_rk,
        COALESCE(cred.sum_credit, 0) AS credit_amount,
        COALESCE(cred.sum_credit, 0) * COALESCE(er_c.reduced_cource, 1) AS credit_amount_rub,
        COALESCE(deb.sum_debet, 0)  AS debet_amount,
        COALESCE(deb.sum_debet, 0) * COALESCE(er_d.reduced_cource, 1) AS debet_amount_rub
    FROM
        ds.md_account_d act
        LEFT JOIN (
            SELECT credit_account_rk AS account_rk, SUM(credit_amount::NUMERIC) AS sum_credit
            FROM ds.ft_posting_f
            WHERE oper_date = i_OnDate
            GROUP BY credit_account_rk
        ) cred ON cred.account_rk = act.account_rk
        LEFT JOIN (
            SELECT debet_account_rk AS account_rk, SUM(debet_amount::NUMERIC) AS sum_debet
            FROM ds.ft_posting_f
            WHERE oper_date = i_OnDate
            GROUP BY debet_account_rk
        ) deb ON deb.account_rk = act.account_rk
        LEFT JOIN ds.md_exchange_rate_d er_c
            ON er_c.currency_rk = act.currency_rk
            AND i_OnDate BETWEEN er_c.data_actual_date AND er_c.data_actual_end_date
        LEFT JOIN ds.md_exchange_rate_d er_d
            ON er_d.currency_rk = act.currency_rk
            AND i_OnDate BETWEEN er_d.data_actual_date AND er_d.data_actual_end_date
    WHERE
        i_OnDate BETWEEN act.data_actual_date AND act.data_actual_end_date
        AND (cred.account_rk IS NOT NULL OR deb.account_rk IS NOT NULL);
    
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    
    v_end_time := clock_timestamp();
    INSERT INTO logs.etl_log (process_name, start_time, end_time, status, rows_processed, message)
    VALUES ('FILL_TURNOVER', v_start_time, v_end_time, 'SUCCESS', v_rows, 'i_OnDate = ' || i_OnDate::TEXT);
END;
$$;


-- Процедура расчета остатков 
CREATE OR REPLACE FUNCTION ds.fill_account_balance_f(i_OnDate DATE)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_time   TIMESTAMP;
    v_end_time     TIMESTAMP;
    v_rows         INT;
    v_prev_date    DATE;
BEGIN
    v_start_time := clock_timestamp();
    v_prev_date := i_OnDate - INTERVAL '1 day';
    
    INSERT INTO logs.etl_log (process_name, start_time, status, message)
    VALUES ('FILL_BALANCE', v_start_time, 'STARTED', 'i_OnDate = ' || i_OnDate::TEXT);
    
    DELETE FROM dm.dm_account_balance_f WHERE on_date = i_OnDate;
    
    INSERT INTO dm.dm_account_balance_f (on_date, account_rk, balance_out, balance_out_rub)
    SELECT
        i_OnDate,
        act.account_rk,
        CASE act.char_type
            WHEN 'А' THEN COALESCE(prev.balance_out, 0) + COALESCE(turn.debet_amount, 0) - COALESCE(turn.credit_amount, 0)
            WHEN 'П' THEN COALESCE(prev.balance_out, 0) - COALESCE(turn.debet_amount, 0) + COALESCE(turn.credit_amount, 0)
            ELSE 0
        END,
        CASE act.char_type
            WHEN 'А' THEN COALESCE(prev.balance_out_rub, 0) + COALESCE(turn.debet_amount_rub, 0) - COALESCE(turn.credit_amount_rub, 0)
            WHEN 'П' THEN COALESCE(prev.balance_out_rub, 0) - COALESCE(turn.debet_amount_rub, 0) + COALESCE(turn.credit_amount_rub, 0)
            ELSE 0
        END
    FROM
        ds.md_account_d act
        LEFT JOIN dm.dm_account_balance_f prev ON prev.account_rk = act.account_rk AND prev.on_date = v_prev_date
        LEFT JOIN dm.dm_account_turnover_f turn ON turn.account_rk = act.account_rk AND turn.on_date = i_OnDate
    WHERE
        i_OnDate BETWEEN act.data_actual_date AND act.data_actual_end_date;
    
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    
    v_end_time := clock_timestamp();
    INSERT INTO logs.etl_log (process_name, start_time, end_time, status, rows_processed, message)
    VALUES ('FILL_BALANCE', v_start_time, v_end_time, 'SUCCESS', v_rows, 'i_OnDate = ' || i_OnDate::TEXT);
END;
$$;


-- Очищаем данные за 31.12.2017
DELETE FROM dm.dm_account_balance_f WHERE on_date = '2017-12-31';

-- Вставляем остатки с пересчётом по курсу
INSERT INTO dm.dm_account_balance_f (on_date, account_rk, balance_out, balance_out_rub)
SELECT
    b.on_date,
    b.account_rk,
    b.balance_out,
    b.balance_out * COALESCE(er.reduced_cource, 1) AS balance_out_rub
FROM ds.ft_balance_f b
LEFT JOIN ds.md_account_d a
    ON a.account_rk = b.account_rk
    AND b.on_date BETWEEN a.data_actual_date AND a.data_actual_end_date
LEFT JOIN ds.md_exchange_rate_d er
    ON er.currency_rk = a.currency_rk
    AND b.on_date BETWEEN er.data_actual_date AND er.data_actual_end_date
WHERE b.on_date = '2017-12-31';



delete from dm.dm_account_balance_f;
delete from dm.dm_account_turnover_f;


SELECT * FROM dm.dm_account_turnover_f WHERE on_date = '2018-01-15' LIMIT 10;
SELECT * FROM dm.dm_account_balance_f WHERE on_date = '2018-01-31' LIMIT 10;
SELECT * FROM logs.etl_log ORDER BY log_id DESC;



