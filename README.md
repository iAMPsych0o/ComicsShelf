# ComicShelf

Comic and manga collection manager for Panini. Import the catalog from Panini's online stores, organize your comics into collections, track what you own, what you've bought and what you're still missing, and plan your next purchases.

Built with Flutter for **Android**, **iOS** and **Windows**. Everything is stored locally on your device, with no server or account in the cloud.

> *This project is not affiliated with, sponsored by, or endorsed by Panini. Panini is a registered trademark of its respective owners.*

## Features

- **Catalog import** from Panini online stores: Mexico, Chile, Argentina and Brazil. Pick the categories you want and review changes before saving them.
- **Collections**: group comics by series and see, for each one, how much you already have, how much you've bought and how much is left to complete it.
- **Comic status**: mark each comic as *Wishlist*, *Purchased* or *Owned*.
- **Availability badges**: *Pre-order*, *Available* or *Sold out*, based on the last catalog update.
- **Shopping carts**: build several named carts with their total cost, and turn a cart into an order once you buy it.
- **Orders**: track pending and received orders with the store and tracking code. Marking an order as received moves its comics to *Owned*.
- **PDF export** of collections, wishlist, carts, orders and filtered catalog views, with covers, checkboxes, prices and totals.
- **Offline covers**: covers are cached on the device as small WebP images (~30 KB each), with an optional *Wi-Fi only* download mode.
- **Backups**: export and import a single user's data as a `.json` file. An automatic backup is saved before every import (the last 3 are kept).
- **PC ↔ mobile sync without a server**: send your data between devices on the same Wi-Fi network, protected by a 6-digit PIN and AES-256-GCM encryption.
- **Multiple local users**, each with their own collections and statuses.

## Getting started

### Requirements

- [Flutter](https://docs.flutter.dev/get-started/install) (Dart SDK ^3.13)
- For Android: Android Studio / Android SDK
- For Windows: Visual Studio with the *Desktop development with C++* workload

### Run

```bash
git clone https://github.com/iAMPsych0o/ComicsShelf.git
cd ComicsShelf
flutter pub get
flutter run
```

### Build

```bash
flutter build apk --release      # Android
flutter build windows --release  # Windows
```

### App icon

The icon source is `assets/icon/icon_c.svg`. After changing it, export it to a 1024×1024 PNG and regenerate the icons:

```bash
dart run flutter_launcher_icons
```

## Project structure

```
lib/
├── db/          # SQLite database and migrations
├── screens/     # Catalog, collections, wishlist, purchases, sync, settings…
├── services/    # Store scraper, auth, backups, sync, PDF export, cover cache
├── widgets/     # Shared UI components
├── models.dart  # Data models
└── main.dart
```

## Roadmap

- [ ] Package tracking from each order's tracking code
- [ ] Support for more stores beyond Panini

## License

This project is licensed under the [MIT License](LICENSE).
