set -euo pipefail

run_sql_file() {
  local file="$1"
  echo "running init sql: ${file}"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f "$file"
}

for file in /app/db/migrations/*.sql; do
  run_sql_file "$file"
done

run_sql_file /app/db/dev-seeds/0002_dev_gateway_seed.sql
run_sql_file /app/db/dev-seeds/0003_dev_smoke_seed_reconcile.sql
run_sql_file /app/db/dev-seeds/0001_dev_admin_seed.sql
