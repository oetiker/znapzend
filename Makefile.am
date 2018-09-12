# Author: Tobi Oetiker <tobi@oetiker.ch>
# License: Public Domain

AUTOMAKE_OPTIONS =  foreign

SUFFIXES = .1 .man .pm

SUBDIRS = thirdparty lib

BIN = bin/@PACKAGE@ bin/znapzendzetup bin/znapzendztatz
PM :=  $(shell find lib/ -name "*.pm")
MAN = man/znapzend.1 man/znapzendzetup.1 man/znapzendztatz.1
POD = doc/znapzend.pod doc/znapzendzetup.pod doc/znapzendztatz.pod

THIRDPARTY_DIR := $(shell pwd)/thirdparty

GENERATED_EXTRADIST = $(MAN)
EXTRA_DIST = VERSION COPYRIGHT README.md LICENSE CHANGES AUTHORS PERL_MODULES $(BIN) $(PM) \
	$(GENERATED_EXTRADIST) init/README.md init/org.znapzend.plist.in  init/znapzend.default  \
	init/znapzend.service.in  init/znapzend.sysv.in  init/znapzend.upstart.in  init/znapzend.xml.in \
	t/autoscrub.t t/ssh t/znapzend.t t/znapzendztatz.t t/mbuffer \
	t/zfs t/znapzendzetup.t t/zpool

CHANGES: VERSION
	git log --full-history --simplify-merges --dense --no-merges > $@

YEAR := $(shell date +%Y)
DATE := $(shell date +%Y-%m-%d)

if ENABLE_SVCINSTALL

svcdir = @SVCINSTALLDIR@
svc_DATA = init/znapzend.xml

endif

datadir = $(prefix)

README.md COPYRIGHT: VERSION
	$(AM_V_GEN)$(PERL) -i -p -e 's/\d{4}-\d{2}-\d{2}/$(DATE)/g;s/[0-4]\.\d+\.\d+/$(PACKAGE_VERSION)/g'  $@

README: README.md
	cp README.md README

imandir = $(mandir)/man1
iman_DATA = $(MAN)

doc/%.pod: bin/% VERSION
	$(AM_V_GEN)mkdir -p doc;grep -A100000 '=head1 NAME' $< > $@

man/%.1: bin/% VERSION
	$(AM_V_GEN)mkdir -p man; test $(POD2MAN) = "no" || $(POD2MAN) --release=$(VERSION) --center=$(PACKAGE_NAME) $<  > $@

dist_bin_SCRIPTS = $(BIN)

dist-hook: $(POD)  $(MAN) CHANGES
	$(PERL) -i -p -e 's/^my .*# VERSION/my \$$VERSION = q{$(PACKAGE_VERSION)}; # VERSION/' $(distdir)/$(BIN)

install-exec-hook:
	[ "$(PERL5LIB)" = "" ] || cd "$(DESTDIR)$(exec_prefix)" && $(PERL) -i -p -e 's{.*# PERL5LIB}{use lib qw($(PERL5LIB)); # PERL5LIB}' $(BIN) || true
	cd "$(DESTDIR)$(exec_prefix)" && $(PERL) -i -p -e 's{^use .*# LIBDIR}{use lib qw($(libdir)); # LIBDIR}' $(BIN)
	cd "$(DESTDIR)$(exec_prefix)" && $(PERL) -i -p -e 's{^#!.*perl.*}{#!$(PERL)};' $(BIN)
	mkdir -p $(DESTDIR)$(libdir)
	[ ! -d $(THIRDPARTY_DIR)/lib/perl5 ] || cp -fr $(THIRDPARTY_DIR)/lib/perl5/* $(DESTDIR)$(libdir)

check:
	$(PERL) -Ithirdparty/lib/perl5 "-MExtUtils::Command::MM" "-e" "test_harness(0, 'lib','thirdparty/lib/perl5')" t/*.t
