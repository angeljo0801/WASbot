# Firma persistente de WhatsBot

WhatsBot usa un identificador Android fijo:

`com.whatsbot.whatsbot`

Para que una APK futura pueda instalarse encima de la anterior sin desinstalarla, todas las versiones deben firmarse con la misma clave.

Configura estos 4 GitHub Actions Secrets en el repositorio `angeljo0801/WASbot`:

- `WHATSBOT_KEYSTORE_B64`
- `WHATSBOT_KEYSTORE_PASSWORD`
- `WHATSBOT_KEY_ALIAS`
- `WHATSBOT_KEY_PASSWORD`

El workflow falla deliberadamente si falta alguno, para evitar publicar por accidente una APK con firma temporal.

La app también incorpora salvas persistentes en `Descargas/WhatsBot`. Después de la primera migración a la firma estable, las siguientes APK podrán actualizarse encima conservando los datos.
