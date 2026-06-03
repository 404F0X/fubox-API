# Backup and Restore Runbook

This runbook covers the local operations scripts for PostgreSQL and optional
Redis backups. The scripts live under `scripts/` and do not manage application
deployments, Helm releases, or database migrations.

## Dependencies

- PowerShell 5.1 or newer.
- PostgreSQL client tools in `PATH`:
  - `pg_dump` for backup.
  - `pg_restore` for restore.
- Optional Redis backup tool:
  - `redis-cli` for `redis-cli --rdb`.
- Write access to the backup output directory.
- Credentials from a secret manager or local environment variables. Do not put
  plaintext passwords into shell history when avoidable.

## Environment Variables

PostgreSQL can be configured either with `DATABASE_URL` / `POSTGRES_URL` or with
standard libpq variables:

- `PGHOST`
- `PGPORT`
- `PGDATABASE`
- `PGUSER`
- `PGPASSWORD`

Redis can be configured with `REDIS_URL` or separate values:

- `REDIS_HOST`
- `REDIS_PORT`
- `REDIS_DATABASE` or `REDIS_DB`
- `REDIS_USERNAME`
- `REDIS_PASSWORD`

`BACKUP_ROOT` can override the default output root. Each successful backup writes
to a timestamped directory such as `backups/20260602-181500`.

## Backup Examples

Dry-run without touching the database:

```powershell
.\scripts\backup_datastores.ps1 `
  -DryRun `
  -PostgresHost localhost `
  -PostgresDatabase fubox `
  -PostgresUser fubox
```

PostgreSQL backup with environment variables:

```powershell
# Load these values from a secret manager or local protected environment.
$env:PGHOST = "localhost"
$env:PGPORT = "5432"
$env:PGDATABASE = "fubox"
$env:PGUSER = "fubox"

.\scripts\backup_datastores.ps1 -OutputRoot D:\backups\fubox
```

PostgreSQL backup with a connection URL:

```powershell
# Set DATABASE_URL from a secret manager or local protected environment.
.\scripts\backup_datastores.ps1 -OutputRoot D:\backups\fubox
```

PostgreSQL plus Redis RDB backup:

```powershell
$env:REDIS_HOST = "localhost"
$env:REDIS_PORT = "6379"

.\scripts\backup_datastores.ps1 `
  -OutputRoot D:\backups\fubox `
  -IncludeRedis
```

Redis backup is intentionally opt-in because Redis may only hold cache data in
some environments. Enable `-IncludeRedis` when Redis contains persistent rate,
queue, stream, lock, or health state that must be captured for the recovery
point.

## Restore Examples

Restore is dry-run by default:

```powershell
.\scripts\restore_datastores.ps1 `
  -DryRun `
  -BackupPath D:\backups\fubox\20260602-181500 `
  -PostgresHost localhost `
  -PostgresDatabase fubox_restore `
  -PostgresUser fubox
```

Execute PostgreSQL restore after checks:

```powershell
.\scripts\restore_datastores.ps1 `
  -ConfirmRestore `
  -BackupPath D:\backups\fubox\20260602-181500 `
  -PostgresHost localhost `
  -PostgresDatabase fubox_restore `
  -PostgresUser fubox
```

The restore script does not drop or create databases. It calls `pg_restore`
without `--clean` or `--create`, so the target database must already exist and
should normally be empty or prepared specifically for restore validation.

Redis RDB restore is not automated by the script. To restore a Redis RDB, use an
environment-specific service runbook:

1. Confirm the Redis data directory and configured RDB filename.
2. Stop Redis or fail over to a restore target.
3. Keep a copy of the current RDB/AOF files.
4. Replace the configured RDB file with the backup `redis.rdb`.
5. Start Redis and verify `INFO persistence`, key counts, and application
   readiness.

## Restore Pre-checks

- Confirm the backup timestamp, source environment, and intended recovery point.
- Verify the target is not production unless the incident commander has approved
  the restore.
- Confirm the target PostgreSQL database already exists.
- Prefer restoring to a new validation database first.
- Ensure no application writers are connected to the restore target.
- Confirm migrations expected by the running application match the backup.
- Check disk capacity for the expanded PostgreSQL data and Redis RDB.
- Make a fresh backup of the target before any production restore.
- Record who approved `-ConfirmRestore`, the backup path, target database, and
  start/end times in the incident or change ticket.

## Output

A successful backup directory contains:

- `postgres.dump`: PostgreSQL custom-format dump from `pg_dump`.
- `redis.rdb`: Redis RDB file when `-IncludeRedis` is used.
- `metadata.json`: non-secret backup metadata.

Script logs include timestamps and connection summaries, but never print
password values.
