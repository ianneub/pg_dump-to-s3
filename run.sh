#!/bin/bash

set -euo pipefail

# ---------------------------------------------------------------------------
# Optional: if SQL_S3 is set, sync that S3 URL into SQL_DIR (/sql) first.
#
# Behaviour then depends on whether SQL_DIR holds any *.sql (searched
# recursively, so files nested a directory deep by `aws s3 sync` still count):
#
#   No *.sql        -> backup: stream a live pg_dump straight to S3 (unchanged).
#       Required: AWS_BUCKET, PREFIX, PGDATABASE, PGUSER, PGPASSWORD, PGHOST
#
#   *.sql present   -> sanitize: dump the live DB, restore into an ephemeral
#       local Postgres, run every *.sql in SQL_DIR in name order (ON_ERROR_STOP),
#       re-dump, and upload to DEST_S3.
#       Required: PGHOST, PGDATABASE, PGUSER, PGPASSWORD, DEST_S3
#       Optional: SQL_S3, SQL_DIR (default /sql), LOCAL_DB (default sanitize)
# ---------------------------------------------------------------------------

: "${PGDUMP_OPTIONS:=-Fp -Z 9 --no-acl --no-owner}"
SQL_DIR="${SQL_DIR:-/sql}"

require() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "You need to set the ${name} environment variable."
    exit 1
  fi
}

if [ -n "${SQL_S3:-}" ]; then
  mkdir -p "$SQL_DIR"
  echo "Syncing SQL transforms from ${SQL_S3} ..."
  aws s3 sync "$SQL_S3" "$SQL_DIR"
fi

# Find *.sql anywhere under SQL_DIR (recursive), ordered by path name.
mapfile -t sql_scripts < <(find "$SQL_DIR" -type f -name '*.sql' 2>/dev/null | sort)

if [ -n "${SQL_S3:-}" ] && [ ${#sql_scripts[@]} -eq 0 ]; then
  echo "SQL_S3 set but no .sql files synced from ${SQL_S3}. Aborting."
  exit 4
fi

# ---- Backup (default): no transforms present ----
if [ ${#sql_scripts[@]} -eq 0 ]; then
  for v in AWS_BUCKET PREFIX PGDATABASE PGUSER PGPASSWORD PGHOST; do require "$v"; done
  echo "No SQL transforms in ${SQL_DIR}; backing up ${PGDATABASE} from ${PGHOST}..."
  pg_dump $PGDUMP_OPTIONS "$PGDATABASE" \
    | aws s3 cp - "s3://$AWS_BUCKET/$PREFIX/$(date +"%Y")/$(date +"%m")/$(date +"%d").dump" || exit 2
  echo "Done!"
  exit 0
fi

# ---- Sanitize: transforms present in SQL_DIR ----
require DEST_S3
LOCAL_DB="${LOCAL_DB:-sanitize}"
DUMP=/tmp/source.dump
MAX_SOURCE_AGE_HOURS="${MAX_SOURCE_AGE_HOURS:-26}"

if [ -n "${SOURCE_S3:-}" ]; then
  # Restore from the newest .dump under the SOURCE_S3 prefix instead of dumping prod.
  src="${SOURCE_S3#s3://}"; bucket="${src%%/*}"; prefix="${src#*/}"
  echo "Resolving newest .dump under s3://${bucket}/${prefix} ..."
  newest="$(aws s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix" \
    --query 'sort_by(Contents[?ends_with(Key, `.dump`)], &LastModified)[-1].[Key,LastModified]' \
    --output text)"
  if [ -z "$newest" ] || [ "$newest" = "None" ]; then
    echo "No .dump object found under s3://${bucket}/${prefix}. Aborting." >&2
    exit 5
  fi
  key="$(printf '%s' "$newest" | cut -f1)"
  lastmod="$(printf '%s' "$newest" | cut -f2)"
  last_epoch="$(date -d "$lastmod" +%s)"
  age_h=$(( ( $(date +%s) - last_epoch ) / 3600 ))
  echo "Newest dump: ${key} (LastModified ${lastmod}, age ${age_h}h)"
  if [ "$age_h" -gt "$MAX_SOURCE_AGE_HOURS" ]; then
    echo "Newest dump is ${age_h}h old, older than MAX_SOURCE_AGE_HOURS=${MAX_SOURCE_AGE_HOURS}. Aborting (stale)." >&2
    exit 6
  fi
  echo "Downloading s3://${bucket}/${key} -> ${DUMP} ..."
  aws s3 cp "s3://${bucket}/${key}" "$DUMP"
else
  for v in PGHOST PGDATABASE PGUSER PGPASSWORD; do require "$v"; done
  echo "Found ${#sql_scripts[@]} SQL transform(s); dumping ${PGDATABASE} from ${PGHOST}..."
  pg_dump $PGDUMP_OPTIONS "$PGDATABASE" > "$DUMP"
fi

echo "Starting ephemeral local Postgres..."
export PGDATA=/tmp/pgdata
rm -rf "$PGDATA"; mkdir -p "$PGDATA"; chown postgres:postgres "$PGDATA"
gosu postgres initdb -A trust >/dev/null
gosu postgres pg_ctl -D "$PGDATA" -o "-c listen_addresses='' -c fsync=off" -w start

# Local commands must ignore the prod PG* env (which points at the source DB).
local_pg() { gosu postgres env -u PGHOST -u PGPORT -u PGUSER -u PGPASSWORD -u PGDATABASE "$@"; }

local_pg createdb "$LOCAL_DB"
echo "Restoring dump into ${LOCAL_DB}..."
# Restore assumes a gzip-compressed dump (PGDUMP_OPTIONS includes -Z); change this if using -Fc or uncompressed plain output.
gunzip -c "$DUMP" | local_pg psql -v ON_ERROR_STOP=1 -q -d "$LOCAL_DB" >/dev/null

echo "Applying ${#sql_scripts[@]} SQL script(s) from ${SQL_DIR} in name order..."
for f in "${sql_scripts[@]}"; do
  echo "  -> $f"
  local_pg psql -v ON_ERROR_STOP=1 -q -d "$LOCAL_DB" -f "$f"
done

echo "Re-dumping sanitized DB to ${DEST_S3}..."
local_pg pg_dump $PGDUMP_OPTIONS "$LOCAL_DB" | aws s3 cp - "$DEST_S3"

gosu postgres pg_ctl -D "$PGDATA" -w stop
echo "Done!"
exit 0
