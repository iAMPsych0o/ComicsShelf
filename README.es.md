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
- **Pedidos**: sigue tus pedidos pendientes y recibidos con la tienda, la paquetería y el código de envío. Al marcar un pedido como recibido, sus cómics pasan a *Obtenido*.
- **Rastreo de paquetes**: la paquetería se detecta por el número de guía (Estafeta, DHL, FedEx, UPS…) y el botón *Rastrear* abre su página de rastreo.
- **Moneda**: los precios de todas las tiendas se convierten a la moneda que elijas (MXN, USD, EUR…) con el tipo de cambio del día.
- **Exportar a PDF** colecciones, wishlist, carritos, pedidos y vistas filtradas del catálogo, con portadas, casillas para palomear, precios y totales.
- **Portadas sin conexión**: las portadas se guardan en el dispositivo como imágenes WebP pequeñas (~30 KB cada una), con opción de descargarlas *solo con Wi-Fi*.
- **Respaldos**: exporta e importa los datos de un usuario en un archivo `.json`. Antes de cada importación se guarda un respaldo automático (se conservan los últimos 3).
- **Sincronización PC ↔ móvil sin servidor**: envía tus datos entre dispositivos en la misma red Wi-Fi, protegidos con un PIN de 6 dígitos y cifrado AES-256-GCM.
- **Varios usuarios locales**, cada uno con sus propias colecciones y estados.

## Descarga (Windows)

Descarga `ComicShelf-Setup-x.y.z.exe` de la [última versión](https://github.com/iAMPsych0o/ComicsShelf/releases/latest) y ejecútalo. Se instala solo para tu usuario (no pide permisos de administrador) y tus datos quedan en `%APPDATA%\mx.coleccion\comics_panini`, aunque desinstales.

> El instalador todavía no está firmado, así que Windows SmartScreen puede mostrar *"Windows protegió su PC"*. Haz clic en **Más información → Ejecutar de todas formas**.

## Descarga (Android)

Descarga `ComicShelf-x.y.z.apk` de la [última versión](https://github.com/iAMPsych0o/ComicsShelf/releases/latest) desde tu teléfono y ábrelo. La primera vez, Android te pedirá permitir instalar apps desde tu navegador o administrador de archivos.

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

### APK de Android firmado

Los builds de release se firman con la llave indicada en `android/key.properties` (no está en el repositorio). Sin ese archivo, `flutter build apk --release` usa la llave de depuración para que cualquiera pueda compilar el proyecto. Para usar tu propia llave, crea `android/key.properties`:

```properties
storePassword=...
keyPassword=...
keyAlias=...
storeFile=C:/ruta/a/tu-llave-release.jks
```

### Instalador de Windows

Requiere [Inno Setup 6](https://jrsoftware.org/isinfo.php). Compila la app y crea `installer/Output/ComicShelf-Setup-<versión>.exe` (la versión sale de `pubspec.yaml`):

```bash
powershell -ExecutionPolicy Bypass -File installer/build_installer.ps1
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
- [x] Rastreo de paquetes a partir del código de envío de cada pedido
- [ ] Ver el estado del envío dentro de la app
- [ ] Soporte para más tiendas además de Panini

## Licencia

Este proyecto está bajo la [Licencia MIT](LICENSE).
