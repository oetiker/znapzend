# Copyright (C) 2014 Tobias Oetiker
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307, USA.

AUTOMAKE_OPTIONS = foreign

SUFFIXES = .1 .man .pm

SUBDIRS = lib

BIN = bin/@PACKAGE@ bin/znapzendzetup bin/znapzendztatz

PM :=  $(shell find lib/ -name "*.pm")

MAN = man/znapzend.1 man/znapzendzetup.1 man/znapzendztatz.1
POD = doc/znapzend.pod doc/znapzendzetup.pod doc/znapzendztatz.pod

GENERATED_EXTRADIST = $(MAN)
EXTRA_DIST = VERSION COPYRIGHT README.md LICENSE CHANGES AUTHORS setup/build-thirdparty.sh setup/sdbs.inc $(BIN) $(PM) $(GENERATED_EXTRADIST) init/znapzend.xml.in t/autoscrub.t t/ssh t/znapzend.t t/znapzendztatz.t t/mbuffer t/zfs t/znapzendzetup.t t/zpool

YEAR := $(shell date +%Y)
DATE := $(shell date +%Y-%m-%d)

if ENABLE_SVCINSTALL

svcdir = @SVCINSTALLDIR@
svc_DATA = init/znapzend.xml

endif

dist_bin_SCRIPTS = $(BIN)

imandir = $(mandir)/man1
iman_DATA = $(MAN)

doc/%.pod: bin/% VERSION
	$(AM_V_GEN)mkdir -p doc;grep -A100000 '=head1 NAME' $< > $@
        
man/%.1: bin/% VERSION
	$(AM_V_GEN)mkdir -p man; test $(POD2MAN) = "no" || $(POD2MAN) --release=$(VERSION) --center=$(PACKAGE_NAME) $<  > $@
        
README.md COPYRIGHT: VERSION
	$(AM_V_GEN)$(PERL) -i -p -e 's/\d{4}-\d{2}-\d{2}/$(DATE)/g;s/\d+\.\d+\.\d+/$(PACKAGE_VERSION)/g'  $@

install-exec-hook:
	$(AM_V_GEN)[ "$(PERL5LIB)" != "" ] && cd "$(DESTDIR)$(exec_prefix)" && $(PERL) -i -p -e 's{.*# PERL5LIB}{use lib qw($(PERL5LIB)); # PERL5LIB}' $(BIN) || true
	$(AM_V_GEN)cd "$(DESTDIR)$(exec_prefix)" && $(PERL) -i -p -e 's{^#!.*perl.*}{#!$(PERL)};' $(BIN)

dist-hook: $(POD) $(MAN)
	$(AM_V_GEN)cd $(distdir) && $(PERL) -i -p -e '"$(PACKAGE_VERSION)" =~ /(\d+)\.(\d+)\.(\d+)/ and $$v = sprintf("%d.%03d%03d",$$1,$$2,$$3) and s/^\$$VERSION\s+=\s+".+?"/\$$VERSION = "$$d"/;'  $(BIN)
	$(GMAKE) $(MAN)

prebuild:
	$(GMAKE) dist
	tar xvf znapzend-$(PACKAGE_VERSION).tar.gz
	cd znapzend-$(PACKAGE_VERSION) && mkdir -p znapzend-prebuilt-$(PACKAGE_VERSION)
	cd znapzend-$(PACKAGE_VERSION)/znapzend-prebuilt-$(PACKAGE_VERSION) && tar zxvf ../../znapzend-thirdparty-FAT-2014-07-31.tar.gz        
	cd znapzend-$(PACKAGE_VERSION) && ./configure --prefix=`pwd`/znapzend-prebuilt-$(PACKAGE_VERSION)
	cd znapzend-$(PACKAGE_VERSION) && make install
	cd znapzend-$(PACKAGE_VERSION)/znapzend-prebuilt-$(PACKAGE_VERSION) && $(PERL) -i -p -e 's{^#!.*perl.*}{#!/usr/bin/env perl};' $(BIN)
	cd znapzend-$(PACKAGE_VERSION) && tar czf ../znapzend-prebuilt-$(PACKAGE_VERSION).tar.gz znapzend-prebuilt-$(PACKAGE_VERSION)
#END
