FROM debian:bookworm-slim AS ispc-builder

WORKDIR /build

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl xz-utils && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/ispc.tar.gz \
        https://github.com/ispc/ispc/releases/download/v1.30.0/ispc-v1.30.0-linux.tar.gz && \
    mkdir -p /opt/ispc && \
    tar -xzf /tmp/ispc.tar.gz -C /opt/ispc --strip-components=1 && \
    rm -f /tmp/ispc.tar.gz

COPY src/knn.ispc src/

RUN /opt/ispc/bin/ispc src/knn.ispc \
    --arch=x86-64 \
    --target=avx2-i32x8 \
    --cpu=haswell \
    --PIC \
    --opt=fast-math \
    --no-internal-export-functions \
    -O2 \
    -o /build/knn_ispc.o

FROM nimlang/nim:2.2.4-alpine AS builder

ARG IVF_CLUSTERS=8192
ARG IVF_NPROBE=8
ARG IVF_SAMPLE=65536
ARG IVF_ITERATIONS=25
ARG USE_LOCAL_DATA=1
ARG ENABLE_PROFILER=0

WORKDIR /build

RUN apk add --no-cache ca-certificates curl gzip tar wget xz zig

COPY tools/preprocess.nim tools/
COPY data/ data/
RUN if [ "${USE_LOCAL_DATA}" = "1" ] && \
      [ -f ./data/vectors.bin ] && \
      [ -f ./data/labels.bin ] && \
      [ -f ./data/residuals.bin ] && \
      [ -f ./data/ivf.bin ]; then \
        echo "Using local preprocessed data." && \
        mkdir -p /data && \
        cp ./data/*.bin /data/; \
    else \
        echo "Running preprocess step..." && \
        mkdir -p /data && \
        curl -fsSL --retry 5 --retry-delay 2 \
            -o /tmp/references.json.gz \
            https://raw.githubusercontent.com/zanfranceschi/rinha-de-backend-2026/main/resources/references.json.gz && \
        gunzip -f /tmp/references.json.gz && \
        IVF_CLUSTERS=${IVF_CLUSTERS} \
        IVF_NPROBE=${IVF_NPROBE} \
        IVF_SAMPLE=${IVF_SAMPLE} \
        IVF_ITERATIONS=${IVF_ITERATIONS} \
        nim c \
            -d:release \
            --mm:arc \
            --threads:off \
            --opt:speed \
            -o:/usr/local/bin/preprocess \
            tools/preprocess.nim && \
        /usr/local/bin/preprocess /tmp/references.json /data/vectors.bin /data/labels.bin /data/residuals.bin /data/ivf.bin && \
        rm -f /tmp/references.json; \
    fi

COPY build.zig .
COPY src/ src/
COPY --from=ispc-builder /build/knn_ispc.o /tmp/knn_ispc.o

RUN set -eu; \
    build_args="--release=fast -Dcpu=haswell -Dispc-object=/tmp/knn_ispc.o"; \
    if [ "${ENABLE_PROFILER}" = "1" ]; then \
        build_args="$build_args -Denable_profiler=true"; \
    fi; \
    zig build $build_args 2>&1 && \
    ls -la zig-out/bin/

FROM alpine:3.20

WORKDIR /app

# Copy preprocessed data
COPY --from=builder /data/ /data/

# Copy server binary
COPY --from=builder /build/zig-out/bin/rinha-server /app/rinha-server

ENV PORT=8080
ENV DATA_DIR=/data

EXPOSE 8080

CMD ["/app/rinha-server"]
