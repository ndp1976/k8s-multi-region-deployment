FROM python:3.12-slim

WORKDIR /app

# Fix TEMP-1147318-639065: upgrade liblzma5 to >= 5.8.1-1+deb13u2
RUN apt-get update \
    && apt-get install -y --no-install-recommends --only-upgrade liblzma5 \
    && rm -rf /var/lib/apt/lists/*

# Install deps first for layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Run as non-root
RUN adduser --disabled-password --gecos "" appuser
USER appuser

EXPOSE 8080

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--threads", "4", "--timeout", "60", "app:app"]
