# WhatsBot mobile

APK Flutter para consultar las notas creadas desde WhatsApp.

## IA local

La app puede cargar directamente en Android un modelo `.gguf` compatible con llama.cpp. En **Configuración → Inteligencia artificial** el usuario puede elegir:

- **Local en este teléfono**: selecciona cualquier GGUF compatible desde el almacenamiento.
- **Servidor**: conserva la organización del backend mediante OpenAI-compatible/Ollama.
- **Reglas**: no usa un LLM.

Cuando el modo local está activo, la app procesa automáticamente las notas nuevas de WhatsApp al abrir/actualizar la bandeja y sincroniza el resultado al backend. El archivo/mensaje original no se reemplaza.

Android mínimo: API 26.
