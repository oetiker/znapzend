# Copyright (C) 2013 Tobias Oetiker
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

SUBDIRS = backend

EXTRA_DIST = INSTALL COPYRIGHT LICENSE CHANGES AUTHORS setup/build-thirdparty.sh setup/sdbs.inc

YEAR := $(shell date +%Y)
DATE := $(shell date +%Y-%m-%d)

ETC = etc/znapzend.cfg.dist
BIN = bin/@PACKAGE@

PM :=  $(shell find lib/ -name "*.pm")

POD :=  $(shell find lib/ -name "*.pod")

EXTRA_DIST = wildcard t/*.t) $(ETC) $(BIN) $(PM) $(POD)

YEAR := $(shell date +%Y)
DATE := $(shell date +%Y-%m-%d)

datadir = $(prefix)
nobase_data_DATA = $(PM) $(POD) $(ETC)

dist_bin_SCRIPTS = $(BIN)

install-exec-hook:
	[ "$(PERL5LIB)" != "" ] && cd "$(DESTDIR)$(bindir)" && $(PERL) -i -p -e 's{.*# PERL5LIB}{use lib qw($(PERL5LIB)); # PERL5LIB}' *.pl || true
	cd "$(DESTDIR)$(bindir)" && $(PERL) -i -p -e 's{^#!.*perl.*}{#!$(PERL)};' *.pl

dist-hook:
	$(PERL) -i -p -e '"$(PACKAGE_VERSION)" =~ /(\d+)\.(\d+)\.(\d+)/ and $$v = sprintf("%d.%03d%03d",$$1,$$2,$$3) and s/^\$$VERSION\s+=\s+".+?"/\$$VERSION = "$$d"/;'  $(distdir)/bin/znapzend
	$(PERL) -i -p -e 's/#VERSION#/$(PACKAGE_VERSION)/g;s/#YEAR#/$(YEAR)/g;s/#DATE#/$(DATE)/g;'  $(distdir)/README $(distdir)/COPYRIGHT


#END
