# ComicShelf

[English](README.md) | **Español**

Administrador de colecciones de cómics y manga de Panini. Importa el catálogo de las tiendas online de Panini, organiza tus cómics en colecciones, lleva el control de lo que ya tienes, lo que compraste y lo que te falta, y planea tus próximas compras.

Hecha con Flutter para **Android**, **iOS** y **Windows**. Todo se guarda localmente en tu dispositivo, sin servidor ni cuenta en la nube.

> 📱 **Próximamente en Google Play:** la app para Android estará disponible muy pronto en la Play Store.

> *Este proyecto no está afiliado, patrocinado ni respaldado por Panini. Panini es una marca registrada de sus respectivos propietarios.*

## Funciones

- **Importación del catálogo** de las tiendas online de Panini: México, Chile, Argentina y Brasil. Elige las categorías que quieras y revisa los cambios antes de guardarlos.
- **Colecciones**: agrupa los cómics por serie y ve, en cada una, cuánto ya tienes, cuánto has comprado y cuánto te falta para completarla.
- **Estado de cada cómic**: márcalo como *Wishlist*, *Comprado* u *Obtenido*.
- **Etiquetas de disponibilidad**: *Preventa*, *Disponible* o *Agotado*, según la última actualización del catálogo.
- **Carritos de compra**: arma varios carritos con nombre y su costo total, y conviértelos en pedido cuando los compres.
- **Pedidos**: sigue tus pedidos pendientes y recibidos con la tienda y el código de envío. Al marcar un pedido como recibido, sus cómics pasan a *Obtenido*.
- **Exportar a PDF** colecciones, wishlist, carritos, pedidos y vistas filtradas del catálogo, con portadas, casillas para palomear, precios y totales.
- **Portadas sin conexión**: las portadas se guardan en el dispositivo como imágenes WebP pequeñas (~30 KB cada una), con opción de descargarlas *solo con Wi-Fi*.
- **Respaldos**: exporta e importa los datos de un usuario en un archivo `.json`. Antes de cada importación se guarda un respaldo automático (se conservan los últimos 3).
- **Sincronización PC ↔ móvil sin servidor**: envía tus datos entre dispositivos en la misma red Wi-Fi, protegidos con un PIN de 6 dígitos y cifrado AES-256-GCM.
- **Varios usuarios locales**, cada uno con sus propias colecciones y estados.

## Primeros pasos

### Requisitos

- [Flutter](https://docs.flutter.dev/get-started/install) (Dart SDK ^3.13)
- Para Android: Android Studio / Android SDK
- Para Windows: Visual Studio con la carga de trabajo *Desarrollo para el escritorio con C++*

### Ejecutar

```bash
git clone https://github.com/iAMPsych0o/ComicsShelf.git
cd ComicsShelf
flutter pub get
flutter run
```

### Compilar

```bash
flutter build apk --release      # Android
flutter build windows --release  # Windows
```

### Ícono de la app

El ícono original está en `assets/icon/icon_c.svg`. Después de cambiarlo, expórtalo a PNG de 1024×1024 y regenera los íconos:

```bash
dart run flutter_launcher_icons
```

## Estructura del proyecto

```
lib/
├── db/          # Base de datos SQLite y migraciones
├── screens/     # Catálogo, colecciones, wishlist, compras, sincronización, configuración…
├── services/    # Scraper de tiendas, autenticación, respaldos, sincronización, PDF, caché de portadas
├── widgets/     # Componentes de interfaz compartidos
├── models.dart  # Modelos de datos
└── main.dart
```

## Roadmap

- [ ] Publicar la app de Android en Google Play
- [ ] Rastreo de paquetes a partir del código de envío de cada pedido
- [ ] Soporte para más tiendas además de Panini

## Licencia

Este proyecto está bajo la [Licencia MIT](LICENSE).
