#!/bin/bash
# Verify a script that RAISEs aborts the run (fail-closed) inside the image.
set -euo pipefail
cd "$(dirname "$0")/.."

docker build -t pg_dump_to_s3 .

mkdir -p /tmp/sqlfail
cat > /tmp/sqlfail/30_assert.sql <<'SQL'
DO $$ BEGIN RAISE EXCEPTION 'residual PII found'; END $$;
SQL

set +e
docker run --rm -v /tmp/sqlfail:/sql --entrypoint bash pg_dump_to_s3 -c '
  set -e
  export PGDATA=/tmp/pgdata
  mkdir -p "$PGDATA" && chown postgres:postgres "$PGDATA"
  gosu postgres initdb -A trust >/dev/null
  gosu postgres pg_ctl -D "$PGDATA" -o "-c listen_addresses=\"\"" -w start
  gosu postgres createdb sanitize
  for f in $(find /sql -type f -name "*.sql" | sort); do
    gosu postgres psql -v ON_ERROR_STOP=1 -q -d sanitize -f "$f"
  done
'
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL: expected non-zero exit when assert RAISEs"; exit 1; }
echo "PASS: assert script aborts the run (rc=$rc)"
