#  Copyright (C) 2019 Tobias Oetiker

AUTOMAKE_OPTIONS =  foreign

THIRDPARTY_DIR = $(abs_builddir)

#GNU# THIRDPARTY_DIST :+ $(shell test -d cache && find cache -type f )
# THIRDPARTY_DIST = @PERL_THIRDPARTY_DIST@
CPANSNAPV = cpanfile-@PERL_CONFIG_VERSION@.snapshot


#EXTRA_DIST = $(THIRDPARTY_DIST) $(wildcard bin/cpanm)
#EXTRA_DIST = bin/cpanm $(wildcard cpanfile*snapshot)
EXTRA_DIST = bin/cpanm cpanfile*snapshot

all-local: touch

touch: bin/cpanm carton/bin/carton $(CPANSNAPV)
	$(AM_V_at)echo "** Installing Dependencies using $(CPANSNAPV)"
	cp $(CPANSNAPV) ../cpanfile.snapshot
# if ever DBD::ODBC is compiled, make sure we get the utf8 version
	PERL_CPANM_OPT= PERL_CPANM_HOME=$(THIRDPARTY_DIR) DBD_ODBC_UNICODE=1 PERL5LIB=$(THIRDPARTY_DIR)/carton/lib/perl5 PERL_CARTON_PATH=$(THIRDPARTY_DIR) $(PERL) $(THIRDPARTY_DIR)/carton/bin/carton install
	$(AM_V_at)rm -f ../cpanfile.snapshot
	$(AM_V_at)touch touch

bin/cpanm:
	$(AM_V_at)echo "** Installing CPANM tool"
	$(AM_V_at)mkdir -p bin
	$(URL_CAT) https://cpanmin.us > bin/cpanm
	$(AM_V_at)chmod 755 bin/cpanm

carton/bin/carton: bin/cpanm
	$(AM_V_at)echo "** Installing/Checking Carton tool"
	test -x carton/bin/carton || PERL_CPANM_OPT= PERL_CPANM_HOME=$(THIRDPARTY_DIR) $(PERL) bin/cpanm -q --notest --local-lib-contained $(THIRDPARTY_DIR)/carton Carton Date::Parse

$(CPANSNAPV): ../cpanfile carton/bin/carton
	$(AM_V_at)echo "** Installing Dependencies using Carton install"
	test -f $(CPANSNAPV) && cp $(CPANSNAPV) ../cpanfile.snapshot || true
# if ever DBD::ODBC is compiled, make sure we get the utf8 version
	PERL_CPANM_OPT= PERL_CPANM_HOME=$(THIRDPARTY_DIR) DBD_ODBC_UNICODE=1 PERL5LIB=$(THIRDPARTY_DIR)/carton/lib/perl5 PERL_CARTON_PATH=$(THIRDPARTY_DIR) $(PERL) $(THIRDPARTY_DIR)/carton/bin/carton install
	mv ../cpanfile.snapshot $(CPANSNAPV)
	$(AM_V_at)touch touch

update: $(CPANSNAPV)
	$(AM_V_at)echo "** Updating Dependencies using Carton update"
	$(AM_V_at)cp $(CPANSNAPV) ../cpanfile.snapshot
	$(AM_V_at)PERL_CPANM_OPT= PERL_CPANM_HOME=$(THIRDPARTY_DIR) PERL5LIB=$(THIRDPARTY_DIR)/carton/lib/perl5 PERL_CARTON_PATH=$(THIRDPARTY_DIR) $(PERL) $(THIRDPARTY_DIR)/carton/bin/carton update
	$(AM_V_at)mv ../cpanfile.snapshot $(CPANSNAPV)

clean-local:
	ls -1 | grep -v Makefile | grep -v cpanfile |grep -v bin | xargs rm -rf

distclean-local:
	ls -1 | grep -v Makefile | grep -v cpanfile | xargs rm -rf

install-exec-hook:
	cp -fr lib/perl5/* $(DESTDIR)$(libdir)
