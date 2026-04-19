FROM --platform=$BUILDPLATFORM alpine:3.19 AS download
ARG TARGETARCH TARGETVARIANT VERSION

RUN apk add --no-cache curl tar && \
    case "${TARGETARCH}-${TARGETVARIANT}" in \
      amd64-*)  ARCH=x86_64 ;; \
      arm64-*)  ARCH=arm64  ;; \
      arm-v7)   ARCH=armv7  ;; \
      arm-v6)   ARCH=armv6  ;; \
      386-*)    ARCH=i386   ;; \
      *)        echo "unsupported arch ${TARGETARCH}${TARGETVARIANT}"; exit 1 ;; \
    esac && \
    VER="${VERSION#v}" && \
    BASE_URL="https://github.com/OutlineFoundation/tunnel-server/releases/download/${VERSION}" && \
    curl -sSfL "${BASE_URL}/checksums.txt" -o /tmp/checksums.txt && \
    curl -sSfL "${BASE_URL}/outline-ss-server_${VER}_Linux_${ARCH}.tar.gz" -o /tmp/archive.tar.gz && \
    grep "outline-ss-server_${VER}_Linux_${ARCH}.tar.gz" /tmp/checksums.txt | sha256sum -c - && \
    tar xzf /tmp/archive.tar.gz -C /tmp/ outline-ss-server && \
    chmod +x /tmp/outline-ss-server

FROM alpine:3.19
COPY --from=download /tmp/outline-ss-server /outline-ss-server
ENTRYPOINT ["/outline-ss-server"]
