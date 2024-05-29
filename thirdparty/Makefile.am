#  Copyright (C) 2019 Tobias Oetiker

AUTOMAKE_OPTIONS =  foreign
CLEANFILES =

THIRDPARTY_DIR = $(abs_builddir)

#GNU# THIRDPARTY_DIST :+ $(shell test -d cache && find cache -type f )
# THIRDPARTY_DIST = @PERL_THIRDPARTY_DIST@
CPANSNAPV = cpanfile-@PERL_CONFIG_VERSION@.snapshot


#EXTRA_DIST = $(THIRDPARTY_DIST) $(wildcard bin/cpanm)
#EXTRA_DIST = bin/cpanm $(wildcard cpanfile*snapshot)
EXTRA_DIST = bin/cpanm cpanfile*snapshot

all-local: touch

../cpanfile:
	+cd .. && $(MAKE) $(AM_MAKEFLAGS) cpanfile

# NOTE: CPANM pulls a number of dependencies which seem to get installed in
# parallel - in a random chaotic order (pun intended), so a few iterations
# may be required - up to the amount of dependencies in the worst case.
# It seems that neutering inheritance of parallel/nested "make" also helps;
# alternately properly annotating such inheritance (`+` starting the line)
# might also help. Trying both belts and suspenders here.
# To add injury to insult, CPANM also uses `make` and is impacted by e.g.
# the DESTDIR setting (if caller of znapzend `make` passes one) which may
# also be made known via MAKEFLAGS (as of GNU Make).
touch: bin/cpanm carton/bin/carton $(CPANSNAPV)
	$(AM_V_at)echo "** Installing Dependencies using $(CPANSNAPV)"
	cp $(CPANSNAPV) ../cpanfile.snapshot
# if ever DBD::ODBC is compiled, make sure we get the utf8 version
	+$(AM_V_at)TRIES=5 ; unset DESTDIR || true ; unset MAKEFLAGS || true ; \
	 while test "$${TRIES}" -gt 0 ; do \
		PERL_CPANM_OPT= PERL_CPANM_HOME=$(THIRDPARTY_DIR) DBD_ODBC_UNICODE=1 PERL5LIB=$(THIRDPARTY_DIR)/carton/lib/perl5 PERL_CARTON_PATH=$(THIRDPARTY_DIR) $(PERL) $(THIRDPARTY_DIR)/carton/bin/carton install \
		&& exit ; \
		TRIES="`expr $${TRIES} - 1`" ; \
		echo "** RETRY Installing Dependencies using $(CPANSNAPV) (attempts left: $${TRIES})" ; \
		MAKEFLAGS="" ; export MAKEFLAGS ; \
	done
	$(AM_V_at)rm -f ../cpanfile.snapshot
	$(AM_V_at)touch touch

bin/cpanm:
	$(AM_V_at)echo "** Installing CPANM tool"
	$(AM_V_at)mkdir -p bin
	$(URL_CAT) https://cpanmin.us > bin/cpanm
	$(AM_V_at)chmod 755 bin/cpanm

carton/bin/carton: bin/cpanm
	$(AM_V_at)echo "** Installing/Checking Carton tool"
	+$(AM_V_at)TRIES=5 ; unset DESTDIR || true ; unset MAKEFLAGS || true ; \
	 while ! test -x carton/bin/carton ; do \
		PERL_CPANM_OPT= PERL_CPANM_HOME=$(THIRDPARTY_DIR) $(PERL) bin/cpanm -q --notest --local-lib-contained $(THIRDPARTY_DIR)/carton Carton Date::Parse \
		&& exit ; \
		TRIES="`expr $${TRIES} - 1`" ; \
		if test "$${TRIES}" -lt 1 ; then exit 1 ; fi ; \
		echo "** RETRY Installing/Checking Carton tool (attempts left: $${TRIES})" ; \
		MAKEFLAGS="" ; export MAKEFLAGS ; \
	done
	test -x carton/bin/carton

test-deps: ../cpanfile.common ../cpanfile.test carton/bin/carton
	$(AM_V_at)echo "** Installing Test Dependencies using Carton install"
	$(AM_V_at)cat ../cpanfile.common ../cpanfile.test > ../cpanfile
	$(AM_V_at)rm -f ../cpanfile.snapshot
	+$(AM_V_at)TRIES=5 ; unset DESTDIR || true ; unset MAKEFLAGS || true ; \
	 while test "$${TRIES}" -gt 0 ; do \
		PERL_CPANM_OPT= PERL_CPANM_HOME=$(THIRDPARTY_DIR) PERL5LIB=$(THIRDPARTY_DIR)/carton/lib/perl5 PERL_CARTON_PATH=$(THIRDPARTY_DIR) $(PERL) $(THIRDPARTY_DIR)/carton/bin/carton install \
		&& exit ; \
		TRIES="`expr $${TRIES} - 1`" ; \
		echo "** RETRY Installing Test Dependencies using Carton install (attempts left: $${TRIES})" ; \
		MAKEFLAGS="" ; export MAKEFLAGS ; \
	done
	$(AM_V_at)rm -f ../cpanfile ../cpanfile.snapshot
	$(AM_V_at)touch "$@"

CLEANFILES += test-deps

$(CPANSNAPV): ../cpanfile carton/bin/carton
	$(AM_V_at)echo "** Installing Dependencies using Carton install"
	test -f $(CPANSNAPV) && cp $(CPANSNAPV) ../cpanfile.snapshot || true
# if ever DBD::ODBC is compiled, make sure we get the utf8 version
	+$(AM_V_at)TRIES=5 ; unset DESTDIR || true ; unset MAKEFLAGS || true ; \
	 while test "$${TRIES}" -gt 0 ; do \
		PERL_CPANM_OPT= PERL_CPANM_HOME=$(THIRDPARTY_DIR) DBD_ODBC_UNICODE=1 PERL5LIB=$(THIRDPARTY_DIR)/carton/lib/perl5 PERL_CARTON_PATH=$(THIRDPARTY_DIR) $(PERL) $(THIRDPARTY_DIR)/carton/bin/carton install \
		&& exit ; \
		TRIES="`expr $${TRIES} - 1`" ; \
		echo "** RETRY Installing Dependencies using $(CPANSNAPV) (attempts left: $${TRIES})" ; \
		MAKEFLAGS="" ; export MAKEFLAGS ; \
	done
	mv ../cpanfile.snapshot $(CPANSNAPV)
	$(AM_V_at)touch touch

update: $(CPANSNAPV)
	$(AM_V_at)echo "** Updating Dependencies using Carton update"
	$(AM_V_at)cp $(CPANSNAPV) ../cpanfile.snapshot
	+$(AM_V_at)TRIES=5 ; unset DESTDIR || true ; unset MAKEFLAGS || true ; \
	 while test "$${TRIES}" -gt 0 ; do \
		$(AM_V_at)PERL_CPANM_OPT= PERL_CPANM_HOME=$(THIRDPARTY_DIR) PERL5LIB=$(THIRDPARTY_DIR)/carton/lib/perl5 PERL_CARTON_PATH=$(THIRDPARTY_DIR) $(PERL) $(THIRDPARTY_DIR)/carton/bin/carton update \
		&& exit ; \
		TRIES="`expr $${TRIES} - 1`" ; \
		echo "** RETRY Installing Dependencies using $(CPANSNAPV) (attempts left: $${TRIES})" ; \
		MAKEFLAGS="" ; export MAKEFLAGS ; \
	done
	$(AM_V_at)mv ../cpanfile.snapshot $(CPANSNAPV)

clean-local:
	ls -1 | grep -v Makefile | grep -v cpanfile | grep -v bin | xargs rm -rf

distclean-local:
	ls -1 | grep -v Makefile | grep -v cpanfile | xargs rm -rf

install-exec-hook:
	cp -fr lib/perl5/* $(DESTDIR)$(libdir)
