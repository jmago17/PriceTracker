# Puente local para Atajos

En Ajustes → Automatización por notificación, **Puente diario para Atajos** es optativo y está apagado inicialmente. El horario local se configura allí (09:00 por defecto). No comparte hora con `DailyRefreshSettings`: ese servicio solo solicita una oportunidad de fondo cada 24 horas, sin hora diaria fija.

## Configuración manual

1. En Atajos → Automatización → Nueva automatización, **si tu iOS ofrece el disparador Notificación**, elige PriceTracker. La referencia Sidenotes describe ese disparador para iOS 27; no se ha verificado aquí en dispositivo. La app admite iOS 26 y no puede asumir que el disparador exista.
2. Filtra el cuerpo por **`PriceTracker refresh`**. El título es `PriceTracker.bridge`. Si el disparador solo filtra por app, añade una condición sobre el cuerpo para no ejecutar el refresco ante avisos reales de precios.
3. Añade la acción **PriceTracker → Comprobar precios** (`RefreshCatalogIntent`, actualización del catálogo). Selecciona Ejecutar inmediatamente si el sistema lo permite; si exige confirmación, confírmala.
4. Activa el puente, elige hora y envía una prueba. Sal de la app: la prueba se programa para dentro de 5 segundos. Verifica por separado entrega y ejecución. El puente no puede saber si la automatización está creada.

Si no aparece Notificación, usa **Hora del día → Diariamente → PriceTracker → Comprobar precios**, y deja el puente apagado. Puedes desactivar la actualización diaria de mejor esfuerzo para evitar comprobaciones duplicadas.

## Comportamiento y límites

- Notificación **local**, calendario repetible diario, cuerpo estable, `sound = nil`, `badge = nil` e interrupción pasiva. Silenciosa significa sin sonido, **no invisible**: puede figurar en el Centro de notificaciones.
- Una notificación no ejecuta un Atajo automáticamente por sí sola. Se requiere la automatización manual y compatibilidad del sistema. Permisos, concentración, entrega, confirmaciones y límites de ejecución en segundo plano pueden impedir o retrasar el resultado.
- Solo activar o probar puede solicitar permiso, y solo `.alert`, sin pedir sonidos. El permiso del sistema es compartido con las alertas, pero el puente nunca cambia `notifyPriceChanges` ni elimina sus notificaciones.
- Desactivar elimina pendientes y entregadas exclusivamente de los dos IDs `pricetracker.shortcut-bridge.daily` y `.test`. Reprogramar no borra notificaciones entregadas ni usa temporizadores para retirarlas; se conserva la posibilidad de que Atajos las procese.
- Preferencias locales persistidas: `shortcutBridgeEnabled`, `shortcutBridgeHour`, `shortcutBridgeMinute`. Lanzar o volver a activar la escena restaura el mismo ID diario sin pedir autorización. Una prueba no activa la repetición diaria.
- Edición horaria bloqueada durante peticiones al sistema; cancelar invalida operaciones pendientes. Una edición cancela la solicitud de la hora anterior antes de programar la nueva; si falla, se muestra el error y la próxima restauración reintenta la preferencia persistida.
- El intent existente continúa en segundo plano y no llama al puente. No se añade apertura de app ni se crea un bucle de notificación/refresco.

## Validación pendiente

`ShortcutBridgeTests` incluye 11 pruebas unitarias con permisos y entrega inyectados: horario/contenido silencioso, restauración sin prompt, denegación/reintento, prueba sin opt-in, persistencia/ID estable, fallos, carreras de cancelación, edición bloqueada y estados admitidos. Registradas en el target unitario explícito. No ejecutadas aquí: no hay Swift/Xcode local ni acceso al Mac. Se necesita compilar y ejecutar el target PriceTrackerTests y verificar en dispositivo el disparador real, cambio de zona horaria/horario de verano, permisos revocados y entrega con la app cerrada. El harness `Tools/run-core-tests.py` también incluye el servicio y esta suite para ejecutarlos en el Mac sin simulador; esa ejecución sigue pendiente.
