import psycopg2
from datetime import date, timedelta

DB_DSN = "host=localhost port=5433 dbname=demo user=postgres password=3289"

def run_procedure(proc_name, param_date):
    conn = psycopg2.connect(DB_DSN)
    try:
        with conn.cursor() as cur:
            cur.execute(f"SELECT {proc_name}(%s::DATE);", (param_date,))
        conn.commit()
    finally:
        conn.close()

def main():
    start_date = date(2018, 1, 1)
    end_date = date(2018, 1, 31)
    current = start_date
    while current <= end_date:
        print(f"Рассчитываю обороты за {current}")
        run_procedure('ds.fill_account_turnover_f', current)
        print(f"Рассчитываю остатки за {current}")
        run_procedure('ds.fill_account_balance_f', current)
        current += timedelta(days=1)
    print("Расчёт витрин завершён.")

if __name__ == '__main__':
    main()