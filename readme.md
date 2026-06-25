# pg_dump-to-s3

This docker container will backup a Postgres database using pg_dump and stream that to a file on S3.

You must configure awscli inside the container. This can be done using either ENV variables as shown below or any [other method](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html) supported by [awscli](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-welcome.html).

## Example Usage

    docker run -it -e PREFIX=mybackup/path -e AWS_ACCESS_KEY_ID=mykeyid -e AWS_SECRET_ACCESS_KEY=mysecretkey -e AWS_BUCKET=my-s3-bucket -e PGDATABASE=mydatabase -e PGUSER=myuser -e PGPASSWORD=mypassword -e PGHOST=db ianneub/pg_dump_to_s3

## To build

    make

## Sanitize

If `SQL_S3` is set, the script first runs `aws s3 sync $SQL_S3 $SQL_DIR`
(default `/sql`). If any `*.sql` are then present, it switches from plain
backup to sanitize: it dumps the live DB (`PGHOST`/`PGDATABASE`/…), restores it
into an ephemeral local Postgres, runs every `*.sql` in filename order with
`ON_ERROR_STOP=1`, then re-dumps the result to `$DEST_S3`. With no SQL files it
performs the normal live-DB backup to `s3://$AWS_BUCKET/$PREFIX/Y/M/D.dump`.

Sanitize requires: `PGHOST`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, `DEST_S3`.
Optional: `SQL_S3`, `SQL_DIR`, `LOCAL_DB` (default `sanitize`).

A script that `RAISE`s aborts the run before upload.

### Sanitize source: live DB vs. S3 dump

When `*.sql` transforms are present (sanitize mode), the source DB is obtained as:

- **`SOURCE_S3` set** (e.g. `s3://cd-prod-backups/prise/`): download the newest
  `.dump` object under that prefix instead of dumping the live DB. Aborts if no
  object is found, or if the newest object is older than `MAX_SOURCE_AGE_HOURS`
  (default `26`). Requires `SOURCE_S3`, `DEST_S3`. Does **not** require `PG*`.
- **`SOURCE_S3` unset**: live `pg_dump` from `PGHOST` (requires `PGHOST`,
  `PGDATABASE`, `PGUSER`, `PGPASSWORD`).

The S3 dump must be gzip-compressed plain SQL (the default `-Fp -Z 9` backup output).
