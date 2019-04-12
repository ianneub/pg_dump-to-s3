FROM postgres:11.1

RUN apt-get update && apt-get install --no-install-recommends -y python3 python3-pip python3-setuptools && \
  pip3 install awscli --upgrade && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

ENV PGDUMP_OPTIONS -Fc --no-acl --no-owner

ADD run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
