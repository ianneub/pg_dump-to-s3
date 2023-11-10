FROM postgres:15.4

RUN apt-get update && apt-get install --no-install-recommends -y awscli && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

ENV PGDUMP_OPTIONS -Fc --no-acl --no-owner

ADD run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
