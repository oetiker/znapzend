# ZnapZend configure script

AC_INIT([znapzend],m4_esyscmd([tr -d '\n' < VERSION]),[support@oetiker.ch])
AC_PREREQ([2.59])
AC_CONFIG_AUX_DIR(conftools)

AC_MSG_CHECKING(in to see how you are doing)
AC_MSG_RESULT(keep fighting man!)

# need this to allow long path names
AM_INIT_AUTOMAKE([1.9 tar-ustar foreign no-dependencies no-installinfo no-texinfo.tex nostdinc ])
AM_MAINTAINER_MODE

m4_ifdef([AM_SILENT_RULES], [AM_SILENT_RULES([yes])])

AC_PREFIX_DEFAULT(/opt/$PACKAGE_NAME-$PACKAGE_VERSION)

actual_prefix=$prefix
if test x$actual_prefix = xNONE; then
    actual_prefix=$ac_default_prefix
fi


AC_ARG_VAR(PERL,   [Path to local perl binary])
AC_PATH_PROG(PERL, perl, no-perl-found,$actual_prefix/thirdparty/bin:$PATH)
AC_PATH_PROG(POD2MAN, pod2man, no)

ac_perl_version="5.10.1"


if test "x$PERL" != "x"; then
  AC_MSG_CHECKING(for perl version greater than or equal to $ac_perl_version)
  $PERL -e "use $ac_perl_version;" >/dev/null 2>&1
  if test $? -ne 0; then
    AC_MSG_RESULT(no);
    AC_MSG_ERROR(at least version 5.10.1 is required to run bwtreporter)
  else
    AC_MSG_RESULT(ok);
  fi
else
  AC_MSG_ERROR(could not find perl)
fi

AC_ARG_VAR(GMAKE,   [Path to local GNU Make binary])
AC_PATH_PROGS(GMAKE, [gnumake gmake make])

AC_MSG_CHECKING([for gnu make availablility])
if  ( $GMAKE --version 2> /dev/null | grep GNU  > /dev/null 2>&1 );  then
    AC_MSG_RESULT([$GMAKE is GNU make])
else
    AC_MSG_ERROR([GNU make not found. Try setting the GMAKE environment variable.])
fi

AC_MSG_CHECKING(the price for bergulian eckels)
AC_MSG_RESULT(way to expensive!)

AC_ARG_ENABLE(pkgonly,
        AC_HELP_STRING([--enable-pkgonly],
                        [Skip all checking]))
AC_SUBST(enable_pkgonly)


AC_ARG_VAR(PERL5LIB,   [Colon separated list of perl library directories])
AC_SUBST(PERL5LIB)

# Check the necessary Perl modules

mod_ok=1
if test "$enable_pkgonly" != yes; then
   for module in \
     Mojolicious \
     Mojo::IOLoop::ForkCall
   do 
     AC_MSG_CHECKING([checking for perl module '$module'])
     if ${PERL} -e 'use lib qw('$actual_prefix/thirdparty/lib/perl5'); use '$module 2>/dev/null ; then
         AC_MSG_RESULT([Ok])
     else
         AC_MSG_RESULT([Failed])
         mod_ok=0
     fi
   done
   if test x$mod_ok = x0; then
        cat <<NOTES

** Aborting Configure ******************************
   
   If you know where perl can find the missing modules, set
   the PERL5LIB environment variable accordingly.

   FIRST though, make sure that 'perl' starts the perl
   binary you want to use.

   You can install local copies of the missing modules 
   by running

     ./setup/build-thirdparty.sh ${actual_prefix}/thirdparty

NOTES
      exit 1
 fi

fi
                                                                                                                        
AC_CONFIG_FILES([
	Makefile
	init/znapzend.xml
])

AC_SUBST(VERSION)

AC_OUTPUT

cat <<NOTES

** Ready to install **************************************
   
   Settings:

     PERL5LIB = ${PERL5LIB:-"not set"}
     PERL = $PERL

   Note that the Makefiles uses GNU make functionality.
   Continue installation with

     $GMAKE install

NOTES
