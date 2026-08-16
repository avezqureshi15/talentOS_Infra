ARG OPENBAO_VERSION=2.2.0
FROM openbao/openbao:${OPENBAO_VERSION}

ENV HOME=/root

COPY config.hcl /bao/config.hcl
COPY entrypoint.sh /bao/entrypoint.sh
COPY policies/ /policies/

RUN chmod +x /bao/entrypoint.sh

EXPOSE 8200

ENTRYPOINT ["/bao/entrypoint.sh"]
