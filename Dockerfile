FROM python:3.12-slim

WORKDIR /app

COPY backend/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY backend/app.py /app/app.py
COPY backend/combo.py /app/combo.py
COPY backend/remittances.py /app/remittances.py
COPY backend/assistant_features.py /app/assistant_features.py
COPY backend/main.py /app/main.py

ENV PORT=8080
EXPOSE 8080

CMD ["sh", "-c", "uvicorn app:app --host 0.0.0.0 --port ${PORT:-8080}"]
