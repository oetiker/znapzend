
##### Builder image
ARG PERL_BUILD_VERSION=5.30-buster
ARG ALPINE_VERSION=3.11
FROM docker.io/library/perl:${PERL_BUILD_VERSION} as builder

WORKDIR /usr/local/src

COPY . /usr/local/src

RUN \
  ./configure --prefix=/opt/znapzend && \
  make && \
  make install

##### Runtime image
FROM docker.io/library/alpine:${ALPINE_VERSION} as runtime

ARG PERL_VERSION=5.30.1-r0

RUN \
  # nano is for the interactive "edit" command in znapzendzetup if preferred over vi
  apk add --no-cache zfs curl bash nano perl=${PERL_VERSION} openssh && \
  # mbuffer is not in main currently
  apk add --no-cache --repository http://dl-3.alpinelinux.org/alpine/edge/testing/ mbuffer && \
  ln -s /dev/stdout /var/log/syslog && \
  ln -s /usr/bin/perl /usr/local/bin/perl

COPY --from=builder /opt/znapzend/ /opt/znapzend

RUN \
  ln -s /opt/znapzend/bin/znapzend /usr/bin/znapzend && \
  ln -s /opt/znapzend/bin/znapzendzetup /usr/bin/znapzendzetup && \
  ln -s /opt/znapzend/bin/znapzendztatz /usr/bin/znapzendztatz

ENTRYPOINT [ "/bin/bash", "-c" ]
CMD [ "znapzend --logto=/dev/stdout" ]

##### Tests
FROM builder as test

RUN \
  ./test.sh
