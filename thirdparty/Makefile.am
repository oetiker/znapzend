#  Copyright (C) 2020 Tobias Oetiker

AUTOMAKE_OPTIONS =  foreign

THIRDPARTY_DIR := $(shell pwd)

CPANSNAPV := cpanfile-$(shell $(PERL) -MConfig -e 'print $$Config{version}').snapshot

#EXTRA_DIST = $(THIRDPARTY_DIST) $(wildcard bin/cpanm)
EXTRA_DIST = bin/cpanm $(wildcard cpanfile*snapshot)

all-local: touch

touch:  bin/cpanm $(CPANSNAPV)
	$(AM_V_at)echo "** Installing Dependencies using cpanm and $(CPANSNAPV)"
	$(AM_V_at)cp $(CPANSNAPV) ../cpanfile.snapshot
#	PERL_CPANM_HOME=$(THIRDPARTY_DIR) $(PERL) bin/cpanm -q --notest --local-lib-contained $(THIRDPARTY_DIR) $(shell test -f ../cpanfile.snapshot && echo --mirror file://$(THIRDPARTY_DIR)/cache) --installdeps ..
	PERL_CPANM_HOME=$(THIRDPARTY_DIR) $(PERL) bin/cpanm -q --notest --local-lib-contained $(THIRDPARTY_DIR) --installdeps ..
	$(AM_V_at)rm -f ../cpanfile.snapshot
	$(AM_V_at)touch touch

bin/cpanm:
	$(AM_V_at)mkdir -p bin
	$(URL_CAT) https://cpanmin.us > bin/cpanm
	$(AM_V_at)chmod 755 bin/cpanm

$(CPANSNAPV): ../cpanfile
	$(AM_V_at)echo "** Installing Dependencies using Carton install"
	$(AM_V_at)test -f $(CPANSNAPV) && cp $(CPANSNAPV) ../cpanfile.snapshot || true
	$(AM_V_at)test -x carton/bin/carton || $(PERL) bin/cpanm -q --notest --local-lib-contained $(THIRDPARTY_DIR)/carton Carton
	$(AM_V_at)PERL5LIB=$(THIRDPARTY_DIR)/carton/lib/perl5 PERL_CARTON_PATH=$(THIRDPARTY_DIR) $(PERL) $(THIRDPARTY_DIR)/carton/bin/carton install
	$(AM_V_at)mv ../cpanfile.snapshot $(CPANSNAPV)
	$(AM_V_at)touch touch
#	PERL5LIB=$(THIRDPARTY_DIR)/carton/lib/perl5 PERL_CARTON_PATH=$(THIRDPARTY_DIR) $(PERL) $(THIRDPARTY_DIR)/carton/bin/carton bundle
#	rm -rf cache
#	mv ../vendor/cache .

update: $(CPANSNAPV)
	$(AM_V_at)echo "** Updating Dependencies using Carton update"
	$(AM_V_at)cp $(CPANSNAPV) ../cpanfile.snapshot
	$(AM_V_at)PERL5LIB=$(THIRDPARTY_DIR)/carton/lib/perl5 PERL_CARTON_PATH=$(THIRDPARTY_DIR) $(PERL) $(THIRDPARTY_DIR)/carton/bin/carton update
	$(AM_V_at)mv ../cpanfile.snapshot $(CPANSNAPV)

clean-local:
#	ls -1 | grep -v Makefile | grep -v bin | grep -v cache | xargs rm -rf
	ls -1 | grep -v Makefile | grep -v cpanfile | grep -v bin | xargs rm -rf

distclean-local:
	ls -1 | grep -v Makefile | grep -v cpanfile | xargs rm -rf

install-exec-hook:
	cp -fr lib/perl5/* $(DESTDIR)$(libdir)
