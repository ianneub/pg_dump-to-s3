#!/bin/bash

set -e

if [ -z "${AWS_BUCKET}" ]; then
  echo "You need to set the AWS_BUCKET environment variable."
  exit 1
fi

if [ -z "${PREFIX}" ]; then
  echo "You need to set the PREFIX environment variable."
  exit 1
fi

if [ -z "${PGDATABASE}" ]; then
  echo "You need to set the PGDATABASE environment variable."
  exit 1
fi

if [ -z "${PGUSER}" ]; then
  echo "You need to set the PGUSER environment variable."
  exit 1
fi

if [ -z "${PGPASSWORD}" ]; then
  echo "You need to set the PGPASSWORD environment variable."
  exit 1
fi

if [ -z "${PGHOST}" ]; then
  echo "You need to set the PGHOST environment variable."
  exit 1
fi

POSTGRES_HOST_OPTS=""

echo "Starting dump of ${PGDATABASE} database(s) from ${PGHOST}..."

pg_dump $PGDUMP_OPTIONS $POSTGRES_HOST_OPTS $PGDUMP_DATABASE | aws s3 cp - s3://$AWS_BUCKET/$PREFIX/$(date +"%Y")/$(date +"%m")/$(date +"%d").dump || exit 2

echo "Done!"

exit 0
