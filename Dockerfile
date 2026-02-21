# --- Stage 1: Build ---
FROM ubuntu:24.04 AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc make libc6-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY spoof_hw.c spoof_hw.h fake_cpuinfo.h detect_cpuid.c Makefile ./
RUN make all

# --- Stage 2: Runtime ---
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    pciutils dmidecode i2c-tools coreutils && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=builder /build/spoof_hw.so /build/detect_cpuid ./
COPY launcher.sh detect.sh ./
RUN chmod +x launcher.sh detect.sh detect_cpuid
ENTRYPOINT ["/app/launcher.sh"]
