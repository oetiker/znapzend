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

BIN = bin/@PACKAGE@ bin/znapzendzetup

PM :=  $(shell find lib/ -name "*.pm")

MAN = man/znapzend.1 man/znapzendzetup.1

GENERATED_EXTRADIST = $(MAN)
EXTRA_DIST = COPYRIGHT README LICENSE CHANGES AUTHORS setup/build-thirdparty.sh setup/sdbs.inc $(BIN) $(PM) $(GENERATED_EXTRADIST)

YEAR := $(shell date +%Y)
DATE := $(shell date +%Y-%m-%d)

datadir = $(prefix)

nobase_data_DATA = $(PM) $(POD)

dist_bin_SCRIPTS = $(BIN)

imandir = $(mandir)/man1
iman_DATA = $(MAN)

doc/znapzend.pod: bin/znap

man/znapzend.1: bin/znapzend
	$(AM_V_GEN)mkdir -p man;@POD2MAN@ --release=$(VERSION) --center=@PACKAGE@ $<  > $@
	grep -A100000 '=head1 NAME' $< > doc/znapzend.pod
        
man/znapzendzetup.1: bin/znapzendzetup
	$(AM_V_GEN)mkdir -p man;@POD2MAN@ --release=$(VERSION) --center=@PACKAGE@ $<  > $@
	grep -A100000 '=head1 NAME' $< > doc/znapzendzetup.pod

README COPYRIGHT: VERSION
	$(AM_V_GEN)$(PERL) -i -p -e 's/\d{4}-\d{2}-\d{2}/$(DATE)/g;s/\d+\.\d+\.\d+/$(PACKAGE_VERSION)/g'  $@

install-exec-hook:
	$(AM_V_GEN)[ "$(PERL5LIB)" != "" ] && cd "$(DESTDIR)$(exec_prefix)" && $(PERL) -i -p -e 's{.*# PERL5LIB}{use lib qw($(PERL5LIB)); # PERL5LIB}' $(BIN) || true
	$(AM_V_GEN)cd "$(DESTDIR)$(exec_prefix)" && $(PERL) -i -p -e 's{^#!.*perl.*}{#!$(PERL)};' $(BIN)

dist-hook:
	$(AM_V_GEN)cd $(distdir) && $(PERL) -i -p -e '"$(PACKAGE_VERSION)" =~ /(\d+)\.(\d+)\.(\d+)/ and $$v = sprintf("%d.%03d%03d",$$1,$$2,$$3) and s/^\$$VERSION\s+=\s+".+?"/\$$VERSION = "$$d"/;'  $(BIN)
	



#END
