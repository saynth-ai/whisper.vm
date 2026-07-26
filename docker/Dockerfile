# whisper.cpp HTTP server for FreePBX voicemail transcription.
# Two-stage build: compile whisper.cpp + bake in a model, run the `server` example.
ARG MODEL=base.en

FROM debian:12-slim AS build
ARG MODEL
RUN apt-get update && apt-get install -y --no-install-recommends \
        git make cmake ca-certificates curl clang \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth 1 https://github.com/ggml-org/whisper.cpp .
# Build with clang: GCC 12 on arm64 fails to inline FP16 NEON intrinsics
# (vfmaq_f16 "target specific option mismatch") under -mcpu=native.
# Static libs -> self-contained whisper-server binary (no libwhisper.so to ship).
# clang avoids a GCC-12/arm64 FP16-intrinsic inlining failure; harmless on x86.
RUN cmake -B build -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    && cmake --build build -j --config Release --target whisper-server
RUN bash ./models/download-ggml-model.sh ${MODEL}

FROM debian:12-slim
ARG MODEL
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg libgomp1 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /src/build/bin/whisper-server /app/whisper-server
COPY --from=build /src/models/ggml-${MODEL}.bin /models/model.bin
ENV WHISPER_LANG=en \
    WHISPER_THREADS=4
EXPOSE 8080
# The server accepts POST /inference (multipart 'file') -> JSON {"text": ...}
ENTRYPOINT ["/bin/sh","-c","exec /app/whisper-server -m /models/model.bin -l \"$WHISPER_LANG\" -t \"$WHISPER_THREADS\" --host 0.0.0.0 --port 8080"]
