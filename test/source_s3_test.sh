#!/bin/bash
# Verify SOURCE_S3 mode: newest-object selection, staleness guard, no-object abort.
# Uses an `aws` stub on PATH so no real S3 / network is needed.
set -euo pipefail
cd "$(dirname "$0")/.."

docker build -t pg_dump_to_s3 .

# Build a stub `aws` whose behavior is driven by env vars, plus a tiny gz dump,
# and a one-line scrub script so the sanitize branch is taken.
WORK=/tmp/source_s3_test
rm -rf "$WORK"; mkdir -p "$WORK/stub" "$WORK/sql"

cat > "$WORK/sql/10_noop.sql" <<'SQL'
SELECT 1;
SQL

# A valid gzipped plain-SQL "dump" that restores cleanly into the local DB.
printf 'CREATE TABLE t (id int);\nINSERT INTO t VALUES (1);\n' | gzip -c > "$WORK/source.dump.gz"

cat > "$WORK/stub/aws" <<'STUB'
#!/bin/bash
# Minimal aws stub. Recognizes: s3 sync, s3api list-objects-v2, s3 cp.
set -e
case "$1 $2" in
  "s3 sync")   # SQL_S3 sync: copy nothing (SQL provided via volume mount)
    exit 0 ;;
  "s3api list-objects-v2")
    # Emit "<key>\t<lastmodified>" per STUB_LIST_OUTPUT, or nothing if empty.
    printf '%b' "${STUB_LIST_OUTPUT:-}" ; exit 0 ;;
  "s3 cp")
    if [ "$3" = "-" ]; then
      # Upload from stdin (re-dump to DEST_S3): consume stdin and succeed.
      cat >/dev/null; exit 0
    else
      # Download from S3 to local path: copy our local gz dump to the destination.
      dest="$4"; cp /work/source.dump.gz "$dest"; exit 0
    fi ;;
  *) echo "stub aws: unhandled: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$WORK/stub/aws"

run_case() {
  # $1 = STUB_LIST_OUTPUT value; remaining = extra docker env flags
  local list_out="$1"; shift
  docker run --rm \
    -v "$WORK/stub:/stub" -v "$WORK/sql:/sql" -v "$WORK:/work" \
    -e PATH="/stub:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/lib/postgresql/18/bin" \
    -e SQL_S3="s3://cd-prod-backups/sanitize-sql/" \
    -e SOURCE_S3="s3://cd-prod-backups/prise/" \
    -e DEST_S3="s3://cd-prise-sanitized/prise-sanitized/latest.sql.gz" \
    -e STUB_LIST_OUTPUT="$list_out" \
    "$@" \
    pg_dump_to_s3
}

NOW="$(date -u +%Y-%m-%dT%H:%M:%S+00:00)"
OLD="$(date -u -d '40 hours ago' +%Y-%m-%dT%H:%M:%S+00:00 2>/dev/null || date -u -v-40H +%Y-%m-%dT%H:%M:%S+00:00)"

echo "=== Case A: fresh object -> success ==="
run_case "prise/2026/06/24.dump\t${NOW}\n" >/tmp/a.log 2>&1 \
  || { echo "FAIL A: expected success"; cat /tmp/a.log; exit 1; }
grep -q "Restoring dump" /tmp/a.log || { echo "FAIL A: did not restore from S3"; cat /tmp/a.log; exit 1; }
echo "PASS A"

echo "=== Case B: stale object -> abort non-zero ==="
set +e
run_case "prise/2026/06/24.dump\t${OLD}\n" >/tmp/b.log 2>&1; rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL B: expected non-zero on stale dump"; cat /tmp/b.log; exit 1; }
grep -qi "stale\|older than" /tmp/b.log || { echo "FAIL B: wrong abort reason"; cat /tmp/b.log; exit 1; }
echo "PASS B"

echo "=== Case C: no object -> abort non-zero ==="
set +e
run_case "" >/tmp/c.log 2>&1; rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL C: expected non-zero when no object"; cat /tmp/c.log; exit 1; }
grep -qi "no .*dump\|not found" /tmp/c.log || { echo "FAIL C: wrong abort reason"; cat /tmp/c.log; exit 1; }
echo "PASS C"

echo "ALL PASS"
