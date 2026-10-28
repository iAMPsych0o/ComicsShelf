# Pendientes

## ✅ 1. Exportar e importar respaldos (hecho)

- Solo desde la sesión: ⚙️ Configuración (abajo a la izquierda; arriba a la derecha en el teléfono).
- Cada respaldo es de UN usuario (archivo `.json`): sus colecciones, estados y los datos de esos
  cómics. No incluye contraseñas ni datos de otros usuarios.
- Importar solo reemplaza los datos del usuario activo; antes guarda un respaldo automático en
  `respaldos_automaticos`.

## ✅ 2. Sincronizar PC y móvil sin servidor (hecho, falta probarlo entre los dos dispositivos)

- ⚙️ → "Sincronizar PC y móvil…" → elegir "PC → Móvil" o "Móvil → PC" en ambos dispositivos.
- Siempre en un solo sentido: el origen reemplaza las colecciones y estados del destino (con
  confirmación y respaldo automático). También viaja el catálogo completo: el destino agrega los
  cómics que no tenga y no cambia los que ya existen.
- El que recibe muestra un PIN de 6 dígitos y se anuncia en la red Wi-Fi (UDP 47320); el que
  envía lo encuentra o se escribe la dirección a mano.
- Datos cifrados con AES-256-GCM (clave = PBKDF2 del PIN + sal aleatoria). El receptor se cierra
  tras 5 PIN incorrectos.
- Pendiente de evaluar: si el descubrimiento automático falla en algunos teléfonos Android
  (filtran broadcast), queda la dirección manual.

## ✅ 3. Ícono de la app (hecho)

- "C" de ComicShelf con lomos de cómic y estallido, sobre rojo. Fuente: `assets/icon/icon_c.svg`.
- Para regenerarlo tras cambiar el SVG: exportar a PNG 1024×1024 y correr
  `dart run flutter_launcher_icons`.
- El nombre visible es "ComicShelf". El nombre interno `comics_panini` no se cambia porque
  define la carpeta de datos en Windows y Android.

## ✅ 4. Scraping de varias tiendas (hecho para Latinoamérica)

- México, Chile, Argentina y Brasil: comparten servidor Magento (tiendapanini.com.mx/graphql con
  el encabezado `Store`: mexico, chile, argentina, default). Un acordeón por tienda en Actualizar
  (secciones y revisión) y selector de tienda en el menú ↻ del catálogo.
- Fuera de México el SKU lleva la tienda (`cl:`, `ar:`, `br:`): Chile y Argentina repiten códigos.
- Moneda elegible en ⚙️ → Moneda; precios y totales se convierten con ExchangeRate-API (diario).
- Colombia: existe en el servidor pero sin productos (revisar más adelante).
- paniniamerica.net: Wix, bloquea el acceso y es de tarjetas coleccionables; descartada.

## ✅ 5. Exportar a PDF (hecho)

- Botón PDF en cada colección (respeta el filtro), Wishlist, carritos, pedidos y en el catálogo
  cuando hay filtros activos (estado, disponibilidad, categoría o búsqueda).
- Incluye portadas (las guardadas), casilla para palomear, estado, disponibilidad, precio y totales.

- Generar una lista en PDF de una colección o de un estado (p. ej. Wishlist, Obtenidos).

## ✅ 6. Badges de disponibilidad en las cards (hecho)

- Preventa = categoría "Preventas" de la tienda o fecha de salida futura.
- La disponibilidad es la de la última vez que se actualizó el catálogo.

- Badge de **Preventa**.
- Badge de **Disponible / Agotado** para saber qué se puede comprar y qué ya no.

## ✅ 7. Sección de pedidos (hecho)

- Pestaña Compras → Pedidos. "Comprado" lo controlan los pedidos: lo marcado "Comprado" fuera de
  un pedido cae en "Compras sin pedido" (ahí quedaron los 69 que ya había). "Marcar como
  recibido" pasa todo a Obtenido. Borrar o quitar de un pedido pendiente regresa a Wishlist.
- Los pedidos y carritos viajan en respaldos y en la sincronización PC ↔ móvil.


- Nueva sección "Pedidos pendientes" / "Pedidos comprados".
- Cada pedido tiene:
  - la tienda donde se compró;
  - los cómics comprados, elegidos del mismo catálogo;
  - el código de envío, para consultarlo rápido sin iniciar sesión en otras páginas.
- Definir qué pasa con los cómics que hoy están en "Comprado".

## 8. Rastreo de paquetes (fase 1 hecha)

- ✅ Fase 1: cada pedido tiene paquetería (Estafeta, DHL, FedEx, UPS, Paquetexpress, Correos de
  México, 99minutos, J&T, Amazon, Mercado Libre u Otra), adivinada por el formato de la guía.
  Botón "Rastrear" abre la página oficial con la guía (Otra / Correos / Mercado Libre → 17TRACK).
- Fase 2 (opcional): estado dentro de la app con la API de 17TRACK. Requiere que el usuario cree
  una cuenta y pegue su clave; confirmar la cuota gratuita al registrarse.

## ✅ 9. Futuras compras (carritos) (hecho)

- Pestaña Compras → Carritos. "Agregar a carrito…" desde el catálogo, la selección, la ficha y la
  wishlist. Muestra el total y cuánto está agotado. "Ya lo compré" lo convierte en pedido.


- Nueva opción "Futuras compras" para armar varios carritos con nombre, con cómics del catálogo.
- Cada carrito muestra su costo total.

## ✅ 10. Costos por colección (hecho)

- En la lista de colecciones y en el encabezado de cada una: Tienes · Comprado · Te falta.

- En cada colección, mostrar cuánto cuesta lo que ya tienes y cuánto cuesta lo que te falta.

## ✅ 11. Optimización de espacio (hecho en PC; falta instalar y revisar en el teléfono)

- Hecho: portadas guardadas en `portadas/` (300 px WebP, ≈ 30 KB c/u), "Solo con Wi-Fi"
  (activado por defecto), "Descargar todas" y "Borrar" en ⚙️ → Portadas; respaldos
  automáticos limitados a los últimos 3 por usuario; VACUUM al abrir, máximo una vez al mes.
- Por revisar en el teléfono: si 300 px se ve nítido en la pantalla del Samsung.


- Reducir lo que ocupa la app en el dispositivo (sobre todo en el teléfono): compactar lo más
  posible, **sobre todo las imágenes**.
- Medición en PC (27-oct-2026, 2042 cómics): base de datos 0.9 MB, portadas 0 (no se guardan en
  disco: se descargan de la tienda cada vez que se abre la app), respaldos automáticos 4.5 MB
  (5 archivos), copia `antes_de_migrar.db` 0.9 MB. Total ≈ 6.3 MB.
- **Guardar las portadas en el dispositivo**:
  - Para qué: verlas sin internet, que carguen más rápido y, sobre todo, no gastar los datos
    móviles del teléfono descargándolas una y otra vez.
  - Guardarlas reducidas al tamaño en que se muestran y en un formato comprimido (p. ej. WebP),
    en lugar de la imagen original de la tienda.
  - La tienda ya las reduce en su servidor: agregar `?width=300&format=webp&quality=70` a la URL
    de la portada (probado el 27-oct-2026). Así se descarga ya chica y se ahorran datos.
  - Medido con 5 portadas: original ≈ 177 KB promedio (hasta 800×1200 px) → 300 px WebP ≈ 21 KB
    (≈ 88 % menos). Estimado para 2042 cómics: ≈ 350 MB originales vs ≈ 45 MB a 300 px.
  - Una sola versión de 300 px para todo (cards y detalle): el detalle tampoco muestra la
    portada grande, así que no hace falta otra descarga.
  - Descargar cada portada una sola vez (al verla o al actualizar el catálogo) y volver a
    bajarla solo si la tienda la cambia.
  - En el teléfono, opción para descargar portadas solo con Wi-Fi.
  - Opción para borrar las portadas guardadas.
- **Respaldos automáticos: conservar solo los últimos 3** y borrar los más viejos al crear uno nuevo.
- Compactar la base de datos (VACUUM) de vez en cuando.

## 12. Tiendas de Europa (investigado 27-oct-2026: bloqueado por Queue-it)

- España, Italia, Reino Unido, Francia y Alemania usan otro Magento (`/shp_esp_es/`, etc.). Su
  API GraphQL responde 403. robots.txt permite las categorías y publican sitemaps.
- El listado HTML trae todo lo necesario (nombre, SKU, precio, fecha de salida, portada; las
  portadas reducidas en WebP funcionan), 12-24 productos por página y solo productos a la venta.
- Pero las páginas que no están en el caché del CDN redirigen a **Queue-it** (sala de espera
  virtual, `panini.queue-it.net`) que solo se pasa con JavaScript en un navegador. Saltarla sería
  evadir una protección del sitio: no se hace. Sin eso, el scraping funciona solo a ratos.
- Cómics a la venta: España 4,707 · Italia 11,913 · Reino Unido 878 · Francia 1,528 ·
  Alemania 14,441. paninistore.com solo vende estampas y tarjetas.
- Opciones si se retoma: (a) lista desde el sitemap público (nombre aproximado y SKU, sin precio
  ni portada); (b) pedir a Panini acceso a datos; (c) agregar cómics europeos a mano.
