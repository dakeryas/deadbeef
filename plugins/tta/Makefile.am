ttapath=@top_srcdir@/plugins/tta
EXTRA_DIST = $(ttapath)/README

if HAVE_TTA
pkglib_LTLIBRARIES = tta.la

tta_la_SOURCES = ttaplug.c filter.h ttadec.c ttadec.h

tta_la_LDFLAGS = -module -avoid-version

tta_la_CFLAGS = $(CFLAGS) -std=c99 -fPIC -I@top_srcdir@/include
endif

