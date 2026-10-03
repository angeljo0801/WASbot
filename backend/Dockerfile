FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY combo.py .
COPY remittances.py .
COPY assistant_features.py .
COPY gmail_oauth.py .
COPY gmail_parser.py .
COPY gmail_reconstruction.py .
COPY ci_signing_vault.py .
COPY main.py .

EXPOSE 8080

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
