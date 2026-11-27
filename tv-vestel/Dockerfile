# Vestel MB130 (ARMv7, soft-float, glibc 2.18) çapraz derleme ortamı.
# Debian'ın hazır gcc-arm-linux-gnueabi paketi zaten soft-float / ARM EABI5 /
# loader /lib/ld-linux.so.3 üretir (gnueabihf DEĞİL). crosstool-NG derlemeye gerek yok.
# Apple Silicon'da buildx ile kurulur; derlenen binary TV mimarisi (armv7l) içindir.
FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc-arm-linux-gnueabi \
      binutils-arm-linux-gnueabi \
      libc6-dev-armel-cross \
      file \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
