CC      = gcc
CFLAGS  = -Wall -Wextra -O2
LDFLAGS = -ldl -lpthread

.PHONY: all clean

all: libhwcompat.so detect_cpuid

libhwcompat.so: spoof_hw.c spoof_hw.h fake_cpuinfo.h
	$(CC) -shared -fPIC $(CFLAGS) -o $@ spoof_hw.c $(LDFLAGS)

detect_cpuid: detect_cpuid.c
	$(CC) $(CFLAGS) -o $@ detect_cpuid.c

clean:
	rm -f libhwcompat.so detect_cpuid
