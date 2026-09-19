FROM alpine:3.20

RUN apk add --no-cache iproute2 python3

WORKDIR /src
COPY core /src/core
COPY platforms/linux /src/platforms/linux
COPY config /src/config

ENV PYTHONPATH=/src/core:/src/platforms/linux
ENV KERIOSPLIT_PLATFORM=linux
ENV KERIOSPLIT_STATE=/tmp/keriosplit-state

# Smoke: create a fake VPN iface + hijack routes, apply split, verify, restore.
CMD ["/bin/sh", "/src/platforms/linux/docker/smoke.sh"]
