# Author: Tobi Oetiker <tobi@oetiker.ch>
# License: Public Domain

AC_INIT([znapzend],m4_esyscmd([tr -d '\n' < VERSION]),[tobi@oetiker.ch])
AC_PREREQ([2.59])
AC_CONFIG_AUX_DIR(conftools)

AC_MSG_CHECKING(in to see how you are doing)
AC_MSG_RESULT(keep fighting man!)

# need this to allow long path names
AM_INIT_AUTOMAKE([1.9 tar-ustar foreign no-dependencies no-installinfo no-texinfo.tex nostdinc])
AM_MAINTAINER_MODE

m4_ifdef([AM_SILENT_RULES], [AM_SILENT_RULES([yes])])

AC_PREFIX_DEFAULT(/opt/$PACKAGE_NAME-$PACKAGE_VERSION)
dnl Fix this early so we can expand with eval later; note literal single quotes in exec_prefix
AS_IF([test x"${prefix}" = x"NONE"], [prefix="${ac_default_prefix}"])
AS_IF([test x"${exec_prefix}" = x"NONE"], [exec_prefix='${prefix}'])

AC_ARG_VAR(PERL,   [Path to local perl binary])
AC_PATH_PROG(PERL, perl, no)
AC_PATH_PROG(CURL, curl, no)
AC_PATH_PROG(WGET, wget, no)
AC_PATH_PROG(POD2MAN, pod2man, no)

# TODO: with some respect to legacy, split such settings to be named
# after respective service management framework; code supports several
AC_ARG_ENABLE(svcinstall,
        AC_HELP_STRING(
                [--enable-svcinstall=DIR],
                [install svc manifest into given directory]
        ),
        [SVCINSTALLDIR=$enableval],
        [SVCINSTALLDIR=no]
)
AC_SUBST(SVCINSTALLDIR)
AM_CONDITIONAL(ENABLE_SVCINSTALL,[test $SVCINSTALLDIR != no])

SVCNAME_SMF="oep/znapzend"
AC_ARG_WITH(svcname-smf,
        AC_HELP_STRING(
                [--with-svcname-smf=SMF_FMRI],
                [use specified SMF FMRI in manifest (defaults to oep/znapzend)]
        ),
        [AC_MSG_CHECKING([user-provided SMF service name of '$withval'])
         SVCNAME_SMF="`echo "$withval" | sed -e 's,^svc:,,' -e 's,^/*,,' -e 's,:.*$,,'`"
        ],[AC_MSG_CHECKING([default SMF service name])]
)
AC_MSG_RESULT([$SVCNAME_SMF])
AC_SUBST(SVCNAME_SMF)

URL_CAT="neither curl nor wget found"
if test -x "$WGET"; then
    URL_CAT="$WGET -O -"
else
    if test -x "$CURL"; then
        URL_CAT="$CURL --location --insecure"
    fi
fi

AC_SUBST(URL_CAT)


ac_perl_version="5.10.1"

if test "x$PERL" != "x"; then
  AC_MSG_CHECKING(for perl version greater than or equal to $ac_perl_version)
  $PERL -e "use $ac_perl_version;" >/dev/null 2>&1
  if test $? -ne 0; then
    AC_MSG_RESULT(no);
    AC_MSG_ERROR(at least version 5.10.1 is required to run mojolicious)
  else
    AC_MSG_RESULT(ok);
  fi
else
  AC_MSG_ERROR(could not find perl)
fi


AC_MSG_CHECKING(is perl reasonably complete)
if $PERL -MExtUtils::MakeMaker -e '' 2>/dev/null; then
  AC_MSG_RESULT(yes. ExtUtils::MakeMaker is available);
else
  AC_MSG_RESULT(no)
  AC_MSG_ERROR([a complete perl ('perl-core' in the redhat world) installation is required])
fi

AC_MSG_CHECKING([if require a c compiler to get perl modules compiled])
if $PERL -MIO::Socket::IP -e 'exit($IO::Socket::IP::VERSION < 0.37)' 2>/dev/null; then
    AC_MSG_RESULT(no)
else
    AC_MSG_RESULT(yes)
    perl_cc=`$PERL -MConfig -e 'print $Config{cc}'`
    AC_PATH_PROG(PERL_CC_PATH, $perl_cc, no)
    AC_MSG_CHECKING(is perls favorite c compiler ($perl_cc) available)
    if test x$PERL_CC_PATH = xno; then
        AC_MSG_RESULT(no)
        AC_MSG_ERROR([perl needs the '$perl_cc' compiler package to build dependencies])
    else
        AC_MSG_RESULT(yes)
    fi
fi

AC_PROG_GREP

AC_ARG_VAR(GMAKE,   [Path to local GNU Make binary])
AC_PATH_PROGS(GMAKE, [gnumake gmake make])

AC_MSG_CHECKING([for gnu make availablility])
if  ( $GMAKE --version 2> /dev/null | $GREP GNU  > /dev/null 2>&1 );  then
    AC_MSG_RESULT([$GMAKE is GNU make])
else
    AC_MSG_ERROR([GNU make not found. Try setting the GMAKE environment variable.])
fi

AC_ARG_ENABLE(pkgonly,
        AC_HELP_STRING([--enable-pkgonly],
                        [Skip all checking]))
AC_SUBST(enable_pkgonly)

# TODO: Is this block needed? No code seems to refer this varname...
actual_prefix=$prefix
if test x$actual_prefix = xNONE; then
    actual_prefix=$ac_default_prefix
fi

AC_MSG_CHECKING(the price for bergulian eckels)
AC_MSG_RESULT(way to expensive!)

AC_ARG_VAR(PERL5LIB,   [Colon separated list of perl library directories])
AC_SUBST(PERL5LIB)

dnl Autotools default expansion of path settings results in further $variables
dnl so for practical use in static configs this yarn has to be fully unrolled:
dnl expand ${prefix} and write it out
conftemp="${prefix}"
eval conftemp=\"${conftemp}\"
eval conftemp=\"${conftemp}\"
PREFIX=${conftemp}
AC_DEFINE_UNQUOTED(PREFIX, "${conftemp}", [Default base path for architecture-independent product files])
AC_SUBST(PREFIX)

dnl same for exec_prefix
conftemp="${exec_prefix}"
eval conftemp=\"${conftemp}\"
eval conftemp=\"${conftemp}\"
EXEC_PREFIX=${conftemp}
AC_DEFINE_UNQUOTED(EXEC_PREFIX, "${conftemp}", [Default base path for architecture-dependent product files])
AC_SUBST(EXEC_PREFIX)

dnl same for datadir
conftemp="${datadir}"
eval conftemp=\"${conftemp}\"
eval conftemp=\"${conftemp}\"
DATADIR=${conftemp}
AC_DEFINE_UNQUOTED(DATADIR, "${conftemp}", [Default path for data files])
AC_SUBST(DATADIR)

dnl same for sysconfdir
conftemp="${sysconfdir}"
eval conftemp=\"${conftemp}\"
eval conftemp=\"${conftemp}\"
SYSCONFDIR=${conftemp}
AC_DEFINE_UNQUOTED(SYSCONFDIR, "${conftemp}", [Default path for configuration files])
AC_SUBST(SYSCONFDIR)

dnl same for bindir
conftemp="${bindir}"
eval conftemp=\"${conftemp}\"
eval conftemp=\"${conftemp}\"
BINDIR=${conftemp}
AC_DEFINE_UNQUOTED(BINDIR, "${conftemp}", [Default path for user executables])
AC_SUBST(BINDIR)

dnl same for sbindir
conftemp="${sbindir}"
eval conftemp=\"${conftemp}\"
eval conftemp=\"${conftemp}\"
SBINDIR=${conftemp}
AC_DEFINE_UNQUOTED(SBINDIR, "${conftemp}", [Default path for system executables])
AC_SUBST(SBINDIR)

dnl same for libdir
conftemp="${libdir}"
eval conftemp=\"${conftemp}\"
eval conftemp=\"${conftemp}\"
LIBDIR=${conftemp}
AC_DEFINE_UNQUOTED(LIBDIR, "${conftemp}", [Default path for system libraries])
AC_SUBST(LIBDIR)

AC_CONFIG_FILES([
    Makefile
    thirdparty/Makefile
    lib/Makefile
    init/znapzend.service
    init/znapzend.sysv
    init/znapzend.upstart
    init/znapzend.xml
    init/org.znapzend.plist
])

AC_SUBST(VERSION)

AC_OUTPUT

if test x$mod_ok = x0; then
    cat <<NOTES

** SOME PERL MODULES ARE MISSING ******************************

If you know where perl can find the missing modules, set
the PERL5LIB environment variable accordingly. Otherwise
just proceed and the missing modules will be installed
automatically.
NOTES

fi

cat <<NOTES

** CONFIGURE DONE **********************************************

Settings:

  PERL5LIB = ${PERL5LIB:-"not set"}
  PERL = $PERL
  SVCINSTALLDIR = $SVCINSTALLDIR

The Makefiles use GNU make functionality.
Continue installation with

  $GMAKE install

NOTES
