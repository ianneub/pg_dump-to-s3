# pg_dump-to-s3

This docker container will backup a Postgres database using pg_dump and stream that to a file on S3.

You must configure awscli inside the container. This can be done using either ENV variables as shown below or any [other method](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html) supported by [awscli](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-welcome.html).

## Example Usage

    docker run -it -e PREFIX=mybackup/path -e AWS_ACCESS_KEY_ID=mykeyid -e AWS_SECRET_ACCESS_KEY=mysecretkey -e AWS_BUCKET=my-s3-bucket -e PGDATABASE=mydatabase -e PGUSER=myuser -e PGPASSWORD=mypassword -e PGHOST=db ianneub/pg_dump_to_s3

## To build

    make
