FROM python:3.12-slim@sha256:c3d81d25b3154142b0b42eb1e61300024426268edeb5b5a26dd7ddf64d9daf28

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN groupadd --system challanse && useradd --system --gid challanse --home-dir /app challanse
WORKDIR /app

COPY requirements.txt ./
RUN python -m pip install --requirement requirements.txt

COPY app ./app
COPY migrations ./migrations
USER challanse
EXPOSE 8080
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
