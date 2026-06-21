UNAME := $(shell uname)
ifeq ($(UNAME), Darwin)
  DYLIB_EXT := dylib
  CFLAGS_SHARED := -dynamiclib
else
  DYLIB_EXT := so
  CFLAGS_SHARED := -shared -fPIC
endif

CC ?= cc
CFLAGS := -O2 -Wall -Wextra

SSL_CFLAGS := $(shell pkg-config --cflags openssl 2>/dev/null)
SSL_LDFLAGS := $(shell pkg-config --libs openssl 2>/dev/null)

.PHONY: all clean

all: libkaappi_net.$(DYLIB_EXT)

libkaappi_net.$(DYLIB_EXT): csrc/kaappi_net.c
	$(CC) $(CFLAGS) $(SSL_CFLAGS) $(CFLAGS_SHARED) -o $@ $< $(SSL_LDFLAGS)

clean:
	rm -f libkaappi_net.dylib libkaappi_net.so
