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
    ARCHIVE="outline-ss-server_${VER}_linux_${ARCH}.tar.gz" && \
    curl -sSfL "${BASE_URL}/checksums.txt" -o /tmp/checksums.txt && \
    curl -sSfL "${BASE_URL}/${ARCHIVE}" -o /tmp/archive.tar.gz && \
    EXPECTED=$(grep "  ${ARCHIVE}$" /tmp/checksums.txt | awk '{print $1}') && \
    echo "${EXPECTED}  /tmp/archive.tar.gz" | sha256sum -c - && \
    tar xzf /tmp/archive.tar.gz -C /tmp/ outline-ss-server && \
    chmod +x /tmp/outline-ss-server

FROM alpine:3.19
COPY --from=download /tmp/outline-ss-server /outline-ss-server
ENTRYPOINT ["/outline-ss-server"]
