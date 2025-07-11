FROM ghcr.io/berriai/litellm:main-latest

WORKDIR /app

COPY config.yaml .

RUN chmod +x ./docker/entrypoint.sh

EXPOSE 4000/tcp

CMD ["--port", "4000", "--config", "config.yaml"]