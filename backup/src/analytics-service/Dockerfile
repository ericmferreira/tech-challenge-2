# --- BUILDER ---
FROM python:3.9 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

RUN python3.9 -m venv /app/venv

ENV PATH="/app/venv/bin:$PATH"

COPY requirements.txt .

RUN pip install --upgrade pip && \
    pip install setuptools==69.5.1 && \
    pip install Werkzeug==2.2.3 && \
    pip install --no-cache-dir -r requirements.txt

# --- RUNNER ---
FROM python:3.9-slim AS runner

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    wget \
    && rm -rf /var/lib/apt/lists/*

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/app/venv/bin:$PATH"

COPY --from=builder /app/venv /app/venv

WORKDIR /app
        
RUN useradd -m appuser && chown -R appuser:appuser /app

COPY . .

USER appuser

EXPOSE 8005

CMD ["gunicorn", "--bind", "0.0.0.0:8005", "app:app"]