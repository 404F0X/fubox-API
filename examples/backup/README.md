# Backup and restore examples

These examples use the minimal PostgreSQL scripts in `scripts/db`.

Dry-run a backup plan without requiring `pg_dump`:

```powershell
$env:DATABASE_URL = "postgres://fubox:<secret>@localhost:5432/fubox"
.\scripts\db\backup.ps1 -DryRun -OutputPath .\backups\db\postgres-dev.dump
```

Run a backup. If the output file already exists, `-Force` is required to
overwrite that file:

```powershell
.\scripts\db\backup.ps1 -OutputPath D:\backups\fubox\postgres-20260602.dump
```

Dry-run a restore. Restore does not execute unless `-Force` is passed:

```powershell
$env:DATABASE_URL = "postgres://fubox:<secret>@localhost:5432/fubox_restore"
.\scripts\db\restore.ps1 -InputPath D:\backups\fubox\postgres-20260602.dump
```

Preflight validates the input file and target connection, but only warns if
`pg_restore` is not installed locally:

```powershell
.\scripts\db\restore.ps1 -Preflight -InputPath D:\backups\fubox\postgres-20260602.dump
```

Execute restore only after confirming the target database is prepared for the
restore:

```powershell
.\scripts\db\restore.ps1 -Force -InputPath D:\backups\fubox\postgres-20260602.dump
```
