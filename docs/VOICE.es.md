# Ivy Display

Pantalla Flutter para Lenovo Smart Display, con voz a través de un satélite
Wyoming TCP en el puerto **10700** y la API existente en **2971**.

Tras instalar la app, añadir cada pantalla en Home Assistant mediante la
integración **Wyoming Protocol** (descubrimiento mDNS o IP y puerto 10700).
Asignar el área correcta, seleccionar el asistente **Ivy**, con palabra de
activación en Home Assistant, y exponer la entidad `assist_satellite` a Assist.
La app espera esa conexión para escuchar: ya no inicia su propio pipeline por
WebSocket. La conexión WebSocket de las demás funciones de la pantalla continúa.

Los ajustes del dispositivo `ivy_name` e `ivy_room` proporcionan el nombre y área.
Sin nombre se usa `Ivy-<ANDROID_ID>`. Los nombres deben ser diferentes por pantalla.
Conservar la calibración anterior en los controles de audio de HA:
supresión de ruido **2**, ganancia automática **31 dBFS**, multiplicador de volumen
**2.0**. La palabra de activación sigue siendo **okay_nabu**.

HA gestiona la detección, transcripción, conversación e identidad. Ivy recibe
anuncios PCM S16LE mono/estéreo (8–96 kHz), los convierte a WAV y usa su reproductor
nativo al terminar de recibirlos (máximo 32 MiB por anuncio).
Solo se confirma `played` al finalizar la reproducción, nunca al recibir el audio.
La voz de las respuestas se solicita para el texto visible al recibir
`synthesize`, usando el pipeline Ivy, tanto con tarjetas OpenUI como sin ellas.
El PCM de esas respuestas se descarta por orden de emisión para evitar una
segunda voz o reproducir una respuesta anterior. Una pregunta nueva detiene la
voz anterior e invalida sus peticiones pendientes; sus resultados tardíos se
ignoran. El micrófono sigue enviando audio mientras se genera la voz y se pausa
durante la reproducción. Las tarjetas se conservan y su código no se lee.
El MP3 se descarga primero con el cliente HTTP de la app y se reproduce desde
un archivo por respuesta; Android no abre la URL remota. La descarga tiene un
límite de 10 s y 32 MiB, y el archivo se elimina al terminar o cancelar la voz.

Los anuncios nativos son audio: HA no envía el texto por Wyoming. La API
`announce` de Ivy sigue disponible para anuncios con texto en pantalla.
Los temporizadores nativos de HA hacen sonar la alerta al recibir `timer-finished`;
sus cuentas atrás se gestionan en HA y no se mezclan con los relojes locales.
Durante llamadas no se envía el micrófono a HA ni se reproducen anuncios Wyoming.
La versión de HA consultada soporta anuncios Wyoming, pero no declara soporte
para `assist_satellite.start_conversation` ni `ask_question` en esa integración.

Wyoming no lleva autenticación ni TLS: mantener **10700 en la LAN de confianza**,
sin redirección desde Internet. Esto es independiente del token de la API de HA.

Comprobaciones locales:

```powershell
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm
```

Las pruebas de `test/wyoming_test.dart` usan sockets de loopback y audio sintético;
no conectan a Home Assistant ni emiten sonido. `test/voice_audio_test.dart` comprueba
la voz antes del PCM, las respuestas tardías entre preguntas y los anuncios con
el canal nativo simulado. Ver la sección Wyoming de
la guía de despliegue local para la instalación y verificación pendientes.
