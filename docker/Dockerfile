# whisper.cpp HTTP server for FreePBX voicemail transcription.
# Two-stage build: compile whisper.cpp + bake in a model, run the `server` example.
ARG MODEL=base.en

FROM debian:12-slim AS build
ARG MODEL
RUN apt-get update && apt-get install -y --no-install-recommends \
        git g++ make cmake ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth 1 https://github.com/ggml-org/whisper.cpp .
RUN cmake -B build -DCMAKE_BUILD_TYPE=Release \
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
