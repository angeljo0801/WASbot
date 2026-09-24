# WhatsBot backend + Twilio WhatsApp webhook

Backend compatible con la APK de `mobile/`. Recibe mensajes de WhatsApp desde Twilio, los guarda como notas y expone la API que ya consume la app Android.

## Endpoint del webhook

Una vez desplegado con HTTPS, configura en Twilio:

```
POST https://TU-DOMINIO/webhooks/twilio/whatsapp
```

Ruta en Twilio: **WhatsApp Senders → tu número → Edit Sender → Endpoint configuration → When a message comes in**.

## Variables privadas

Copia `.env.example` y configura las variables en el proveedor donde alojes el backend.

- `TWILIO_ACCOUNT_SID`: empieza por `AC`.
- `TWILIO_API_KEY_SID`: empieza por `SK`.
- `TWILIO_API_SECRET`: secreto mostrado al crear la API key.
- `TWILIO_AUTH_TOKEN`: Auth Token de la cuenta; se usa exclusivamente para validar que el webhook realmente viene de Twilio.
- `TWILIO_WHATSAPP_FROM`: número online de WhatsApp, formato E.164.
- `APP_API_KEY`: clave privada entre la APK y este backend.
- `DATA_DIR`: carpeta persistente para `whatsbot.db`.

No pongas secretos reales dentro del repositorio ni dentro de la APK.

## Ejecutar localmente

```bash
cd backend
python -m venv .venv
# Linux/macOS
source .venv/bin/activate
# Windows PowerShell
# .venv\Scripts\Activate.ps1

pip install -r requirements.txt
uvicorn app:app --reload --port 8080
```

Prueba:

```
GET http://localhost:8080/health
```

## API para la APK

- `GET /health`
- `GET /api/config`
- `PUT /api/config`
- `GET /api/notes`
- `POST /api/notes`
- `PATCH /api/notes/{id}`
- `DELETE /api/notes/{id}`
- `POST /api/whatsapp/send`
- `POST /webhooks/twilio/whatsapp`

Los endpoints bajo `/api/` requieren el header `x-api-key`.

## Seguridad

El webhook valida `X-Twilio-Signature` usando `TWILIO_AUTH_TOKEN`. Si el token no está configurado, el webhook rechaza las solicitudes en vez de aceptar tráfico no autenticado.

Por defecto `ACK_ENABLED=false`, así recibir una nota no provoca un mensaje de respuesta adicional ni otro cargo de WhatsApp/Twilio.
