# SPDX-License-Identifier: AGPL-3.0-only
# CouchSubs Linux sunucusu. Depo kökünden derlenir (linux/build.sh alt modülleri hazırlayıp bunu çağırır):
#   docker build -f linux/Dockerfile -t couchsubs-linux .
# Aşamalar: LG TV paketi → yerel kütüphane (libchiaki + FFmpeg) → .NET yayını → çalışma imajı.
# Bütün aşamalar Ubuntu 24.04 (noble) tabanlıdır; yerel kütüphane derlendiği dağıtımın FFmpeg'ine bağlanır.

# --- LG webOS TV uygulaması (.ipk); sunucu bunu geliştirici modu açık TV'ye kendisi kurar ---
FROM node:22-slim AS tv
RUN npm install -g @webos-tools/cli >/dev/null
WORKDIR /src
COPY tv-webos tv-webos
RUN mkdir -p dist/tv-app && ares-package tv-webos -o dist/tv-app -n && ls -l dist/tv-app

# --- couchsubs_native.so: libchiaki + FFmpeg h264 çözücü üstünde düz C arayüzü ---
FROM mcr.microsoft.com/dotnet/sdk:10.0-noble AS native
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      build-essential cmake ninja-build pkg-config nasm git \
      python3 python3-protobuf protobuf-compiler \
      libssl-dev libjson-c-dev libevent-dev libminiupnpc-dev zlib1g-dev \
      libavcodec-dev libswscale-dev libavutil-dev >/dev/null
WORKDIR /src
COPY third-party third-party
COPY windows/native windows/native
COPY remoteplay/Tests/RemotePlayTests/Fixtures/sample-1080p.h264 /tmp/sample.h264
RUN cmake -S windows/native -B /build -G Ninja -DCMAKE_BUILD_TYPE=Release >/dev/null \
 && cmake --build /build >/dev/null \
 && /build/couchsubs_native_test /tmp/sample.h264 \
 && strip /build/couchsubs_native.so && ls -l /build/couchsubs_native.so

# --- .NET uygulaması ---
FROM mcr.microsoft.com/dotnet/sdk:10.0-noble AS app
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
WORKDIR /src
COPY design design
COPY core/Sources/CouchSubsCore/Resources core/Sources/CouchSubsCore/Resources
COPY mac/CouchSubs/Resources/Localizable.xcstrings mac/CouchSubs/Resources/Localizable.xcstrings
COPY windows/Directory.Build.props windows/Directory.Build.props
COPY windows/src windows/src
COPY linux/CouchSubs.Linux linux/CouchSubs.Linux
COPY --from=tv /src/dist/tv-app dist/tv-app
COPY --from=native /build/couchsubs_native.so windows/native/bin/couchsubs_native.so
RUN dotnet publish linux/CouchSubs.Linux -c Release -o /app --nologo -v q \
 && ls /app/couchsubs_native.so /app/tv-app/*.ipk

# --- Çalışma imajı ---
FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble
# FFmpeg ve libchiaki'nin çalışma zamanı kütüphaneleri, Tesseract (yazı tanıma) ve ssh-keygen (LG geliştirici anahtarı).
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      libavcodec60 libswscale7 libavutil58 libjson-c5 libminiupnpc17 libevent-2.1-7t64 libevent-pthreads-2.1-7t64 libssl3t64 zlib1g \
      libtesseract5 tesseract-ocr-eng openssh-client ca-certificates >/dev/null \
 && rm -rf /var/lib/apt/lists/*
COPY --from=app /app /app
# Eksik bir paylaşımlı kütüphane derleme sırasında yakalansın (çalışırken "PS5 kütüphanesi yok" demesin).
RUN if ldd /app/couchsubs_native.so | grep "not found"; then exit 1; fi \
 && mkdir -p /data && chown "$APP_UID" /data
# OMP_THREAD_LIMIT: Tesseract'ın OpenMP iş parçacıkları kısa satırlarda hız kazandırmaz, işlemciyi doldurur.
ENV COUCHSUBS_DATA=/data \
    HOME=/data \
    OMP_THREAD_LIMIT=1
VOLUME /data
USER $APP_UID
WORKDIR /app
# 8788: panel, 8787: TV uygulamasının bağlandığı altyazı sunucusu. PS5 ve TV'yi ağda bulabilmek için konteyner
# ev ağına doğrudan bağlı çalışmalıdır (docker run --network host; bkz. linux/compose.yml).
EXPOSE 8788 8787
ENTRYPOINT ["dotnet", "/app/couchsubs.dll"]
