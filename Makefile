all: build

build:
	docker build -t pg_dump_to_s3 .
	@echo "Successfully built pg_dump_to_s3"
