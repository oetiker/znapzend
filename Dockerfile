
##### Builder image
ARG PERL_BUILD_VERSION=5.38-buster
ARG ALPINE_VERSION=3.19
FROM docker.io/library/perl:${PERL_BUILD_VERSION} as builder

WORKDIR /usr/local/src

COPY . /usr/local/src

RUN \
  ./bootstrap.sh && \
  ./configure --prefix=/opt/znapzend && \
  make && \
  make install

##### Runtime image
FROM docker.io/library/alpine:${ALPINE_VERSION} as runtime

ARG PERL_VERSION=5.38.2-r0

RUN \
  # mbuffer is not in main currently, and community keys expire over time,
  # so gotta bump ALPINE_VERSION above regularly (and likely PERL_VERSION
  # as dictated by the newer OS release). Request its package first to fail
  # fast in such case. Note that while "--allow-untrusted" might be an option,
  # shared libraries referenced by the binary make an older distro outdated.
  apk add --no-cache --repository http://dl-cdn.alpinelinux.org/alpine/edge/community/ mbuffer && \
  # nano is for the interactive "edit" command in znapzendzetup if preferred over vi
  apk add --no-cache zfs curl bash autoconf automake nano perl=${PERL_VERSION} openssh && \
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
  cpan Devel::Cover && \
  cpan Test::SharedFork

RUN \
  ./test.sh
