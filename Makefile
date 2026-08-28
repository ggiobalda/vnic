CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Wpedantic

.PHONY: all clean

all: rawnc

rawnc: rawnc.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f rawnc
