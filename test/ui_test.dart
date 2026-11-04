import 'package:comics_panini/app_scope.dart';
import 'package:comics_panini/db/app_database.dart';
import 'package:comics_panini/main.dart';
import 'package:comics_panini/models.dart';
import 'package:comics_panini/services/auth_service.dart';
import 'package:comics_panini/screens/home_shell.dart';
import 'package:comics_panini/screens/sync_screen.dart';
import 'package:comics_panini/widgets/comic_widgets.dart';
import 'package:comics_panini/widgets/refresh_menu.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('badges de preventa y disponibilidad en la card', (tester) async {
    Future<void> card(Comic comic) => tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Center(
          child: SizedBox(
            width: 170,
            height: 330,
            child: ComicStatusCard(
              comic: comic,
              status: ComicStatus.unclassified,
              onTap: () {},
              selected: false,
            ),
          ),
        ),
      ),
    );

    await card(
      const Comic(
        sku: 'Q1',
        name: 'Preventa agotada',
        categories: ['DC Comics', 'Preventas'],
        stockStatus: 'OUT_OF_STOCK',
      ),
    );
    expect(find.text('Preventa'), findsOneWidget);
    expect(find.text('Agotado'), findsOneWidget);
    expect(find.text('Disponible'), findsNothing);

    await card(
      const Comic(
        sku: 'Q2',
        name: 'Normal',
        releaseDate: '2020-01-01',
        stockStatus: 'IN_STOCK',
      ),
    );
    expect(find.text('Preventa'), findsNothing);
    expect(find.text('Disponible'), findsOneWidget);

    // Sin información de la tienda: sin etiquetas.
    await card(const Comic(sku: 'Q3', name: 'Viejo'));
    expect(find.text('Disponible'), findsNothing);
    expect(find.text('Agotado'), findsNothing);
  });

  testWidgets(
    'flujo completo: login, agregar serie a nueva colección y marcar',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final db = AppDatabase.inMemory();
      db.upsertComics([
        for (var n = 1; n <= 2; n++)
          Comic(
            sku: 'QABSB00$n',
            name: 'Absolute Batman Vol.$n (TPB)',
            series: 'Absolute Batman TPB',
            seriesCode: 'QABSB',
            number: n,
            categories: const ['DC Comics'],
          ),
        const Comic(
          sku: 'QOTRO001',
          name: 'Otro comic #1',
          number: 1,
          categories: ['Marvel'],
        ),
      ]);
      final auth = AuthService(db);
      await tester.pumpWidget(
        AppScope(db: db, auth: auth, child: const ComicsPaniniApp()),
      );

      // Sin sesión solo se ve el login.
      expect(find.text('Inicia sesión para ver tu catálogo'), findsOneWidget);
      await tester.tap(find.text('¿No tienes cuenta? Crea una'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'tester');
      await tester.enterText(fields.at(1), 'clave1234');
      await tester.enterText(fields.at(2), 'clave1234');
      await tester.tap(find.text('Crear cuenta'));
      await tester.pumpAndSettle();

      // Catálogo → ficha → agregar serie → nueva colección.
      expect(find.text('Absolute Batman Vol.1 (TPB)'), findsOneWidget);
      await tester.tap(find.text('Absolute Batman Vol.1 (TPB)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agregar serie (2)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nueva colección…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Absolute Batman');
      await tester.tap(find.text('Guardar'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('2 agregado(s) a "Absolute Batman"'),
        findsOneWidget,
      );

      // Colecciones → dashboard → abrir → marcar uno como obtenido.
      await tester.tap(find.text('Colecciones').first);
      await tester.pumpAndSettle();
      expect(find.text('Mi colección'), findsOneWidget); // dashboard
      expect(
        find.text('Obtenidos 0 de 2 · comprados 0 · faltan 2'),
        findsOneWidget,
      );
      await tester.tap(find.text('Absolute Batman'));
      await tester.pumpAndSettle();
      Finder inGrid(IconData icon) => find.descendant(
        of: find.byType(GridView),
        matching: find.byIcon(icon),
      );
      expect(inGrid(Icons.help_outline), findsNWidgets(2)); // sin clasificar
      await tester.tap(find.text('Absolute Batman Vol.1 (TPB)'));
      await tester.pumpAndSettle();
      expect(
        find.text('Obtenidos 1 de 2 · comprados 0 · faltan 1'),
        findsOneWidget,
      );
      expect(inGrid(Icons.check), findsOneWidget);
      expect(inGrid(Icons.help_outline), findsOneWidget);

      // Al volver, la lista y el dashboard reflejan el progreso.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        find.text('Obtenidos 1 de 2 · comprados 0 · faltan 1'),
        findsOneWidget,
      );
      expect(find.text('Obtenido 1'), findsOneWidget); // leyenda

      // Catálogo: mover a wishlist desde el menú de la tarjeta.
      Finder cardOf(String name) => find.ancestor(
        of: find.text(name),
        matching: find.byType(ComicStatusCard),
      );
      Future<void> cardMenu(String comicName, String action) async {
        await tester.tap(
          find.descendant(
            of: cardOf(comicName),
            matching: find.byTooltip('Más opciones'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(action).last);
        await tester.pumpAndSettle();
      }

      await tester.tap(find.text('Catálogo').first);
      await tester.pumpAndSettle();
      await cardMenu('Otro comic #1', 'Mover a wishlist');
      // El aviso usa el tono oscuro del estado (texto blanco legible) y se
      // cierra al hacer clic.
      final notice = find.text('Marcado: Wishlist');
      expect(notice, findsOneWidget);
      expect(
        tester.widget<SnackBar>(find.byType(SnackBar)).backgroundColor,
        statusBackground(ComicStatus.wishlist),
      );
      await tester.tap(notice);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(
        find.descendant(
          of: cardOf('Otro comic #1'),
          matching: find.byIcon(Icons.favorite),
        ),
        findsOneWidget,
      );

      // Panel de filtros: conteos por estado y filtro por "Obtenido".
      await tester.tap(find.text('Filtros'));
      await tester.pumpAndSettle();
      final drawer = find.byType(Drawer);
      expect(
        find.descendant(of: drawer, matching: find.text('Clasificados 2 de 3')),
        findsOneWidget,
      );
      Finder optionRow(String label) => find.descendant(
        of: drawer,
        matching: find.widgetWithText(ListTile, label),
      );
      expect(
        find.descendant(of: optionRow('Wishlist'), matching: find.text('1')),
        findsOneWidget,
      );
      // La sección Tienda se ve aunque solo haya cómics de México.
      await tester.scrollUntilVisible(
        find.descendant(of: drawer, matching: find.text('Panini Brasil')),
        100,
        scrollable: find.descendant(
          of: drawer,
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        find.descendant(
          of: optionRow('Panini México'),
          matching: find.text('3'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: optionRow('Panini Brasil'),
          matching: find.text('0'),
        ),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        optionRow('Obtenido'),
        -100,
        scrollable: find.descendant(
          of: drawer,
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(optionRow('Obtenido'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Listo'));
      await tester.pumpAndSettle();
      expect(find.byType(ComicStatusCard), findsOneWidget);
      // El filtro activo se ve y se puede quitar desde la línea de filtros.
      expect(find.widgetWithText(InputChip, 'Obtenido'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(InputChip, 'Obtenido'),
          matching: find.byIcon(Icons.clear),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ComicStatusCard), findsNWidgets(3));

      // Wishlist → marcar comprado → sale de la wishlist.
      await tester.tap(find.text('Wishlist').first);
      await tester.pumpAndSettle();
      expect(find.text('1 cómics en tu wishlist'), findsOneWidget);
      await cardMenu('Otro comic #1', 'Marcar: comprado');
      expect(find.text('Tu wishlist está vacía.'), findsOneWidget);

      // Ficha: el selector cambia el estado (5 opciones).
      await tester.tap(find.text('Catálogo').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Otro comic #1'));
      await tester.pumpAndSettle();
      expect(find.byType(ChoiceChip), findsNWidgets(5)); // estados en la ficha
      await tester.tap(find.widgetWithText(ChoiceChip, 'No me interesa').last);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5)); // cierra la ficha
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: cardOf('Otro comic #1'),
          matching: find.byIcon(Icons.block),
        ),
        findsOneWidget,
      );

      // Cerrar sesión regresa al login.
      await tester.tap(find.byTooltip('Cerrar sesión'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Cerrar sesión'));
      await tester.pumpAndSettle();
      expect(find.text('Inicia sesión para ver tu catálogo'), findsOneWidget);
    },
  );

  testWidgets('en el teléfono la selección usa una barra compacta', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = AppDatabase.inMemory();
    db.upsertComics([
      for (var n = 1; n <= 3; n++)
        Comic(sku: 'QTEST00$n', name: 'Prueba #$n', number: n),
    ]);
    final auth = AuthService(db)..register('tel', 'clave1234');
    await tester.pumpWidget(
      AppScope(db: db, auth: auth, child: const ComicsPaniniApp()),
    );
    await tester.pumpAndSettle();

    // Selecciona dos tarjetas con su casilla.
    await tester.tap(find.byType(Checkbox).at(0));
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pumpAndSettle();
    expect(find.text('2 seleccionado(s)'), findsOneWidget);
    expect(find.byType(ActionChip), findsNothing); // sin la barra grande

    await tester.tap(find.text('Acciones'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marcar: Obtenido'));
    await tester.pumpAndSettle();

    final id = auth.currentUser!.id;
    expect(db.ownedSkus(id), {'QTEST001', 'QTEST002'});
    expect(find.text('2 seleccionado(s)'), findsNothing);

    // El botón ↻ abre el menú de tienda y secciones; "Actualizar ahora" lleva
    // a "Actualizar" con las secciones elegidas.
    RefreshMenuButton.loader = (_) async => const [
      StoreCategory(id: 1, name: 'DC Comics', productCount: 900),
      StoreCategory(id: 2, name: 'Panini Manga', productCount: 500),
      StoreCategory(id: 3, name: 'Marvel', productCount: 800),
    ];
    addTearDown(() => RefreshMenuButton.loader = null);
    await tester.tap(find.byTooltip('Actualizar catálogo de Panini'));
    await tester.pumpAndSettle();
    expect(find.text('Panini México (MXN)'), findsOneWidget);
    expect(find.text('Actualizar ahora (2 secciones)'), findsOneWidget);
    await tester.tap(find.text('Marvel (800)'));
    await tester.pumpAndSettle();
    expect(find.text('Actualizar ahora (1 sección)'), findsOneWidget);
    await tester.tap(find.text('Actualizar ahora (1 sección)'));
    await tester.pump();
    expect(db.getSetting('scraper_categories'), '1');
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Actualizar'),
      ),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
  });

  testWidgets('compras en el teléfono: carrito → pedido → recibido', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = AppDatabase.inMemory();
    db.upsertComics([
      for (var n = 1; n <= 3; n++)
        Comic(
          sku: 'QTEST00$n',
          name: 'Prueba #$n',
          number: n,
          price: n * 100.0,
          stockStatus: 'IN_STOCK',
        ),
    ]);
    final auth = AuthService(db)..register('tel', 'clave1234');
    final id = auth.currentUser!.id;
    await tester.pumpWidget(
      AppScope(db: db, auth: auth, child: const ComicsPaniniApp()),
    );
    await tester.pumpAndSettle();

    // Menú ⋮ de una card → carrito nuevo.
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agregar a carrito…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nuevo carrito…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Noviembre');
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 agregado(s) a "Noviembre"'), findsOneWidget);

    // Selección → Acciones → al mismo carrito.
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Acciones'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agregar a carrito…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Noviembre'));
    await tester.pumpAndSettle();
    expect(db.carts(id).single.total, 300);
    expect(db.statuses(id), isEmpty); // el carrito no cambia estados

    // Compras → carrito → "Ya lo compré".
    await tester.tap(find.text('Compras'));
    await tester.pumpAndSettle();
    expect(find.text('Carritos (1)'), findsOneWidget);
    await tester.tap(find.text('Noviembre'));
    await tester.pumpAndSettle();
    expect(find.text('Total: \$300.00 MXN'), findsOneWidget);
    await tester.tap(find.text('Ya lo compré'));
    await tester.pumpAndSettle();
    final form = find.byType(TextField);
    await tester.enterText(form.at(0), 'Panini México');
    await tester.enterText(form.at(1), 'MX999');
    await tester.tap(find.text('Crear pedido'));
    await tester.pumpAndSettle();

    // Pedido pendiente: guía a la vista, cómics como "Comprado".
    expect(find.text('Guía: MX999'), findsOneWidget);
    expect(find.text('Rastrear en Otra / no sé'), findsOneWidget);
    expect(db.statuses(id).values.toSet(), {ComicStatus.purchased});
    expect(db.carts(id), isEmpty);

    // Recepción: primero llega solo uno (tocándolo, va a "Sin ubicación"),
    // luego el resto (arrastrándolo al cajón de una ubicación elegida).
    final bin = db.createLocation(id, 'Bin 4');
    await tester.tap(find.text('Marcar como recibido…'));
    await tester.pumpAndSettle();
    expect(find.text('¿Qué llegó? · Panini México'), findsOneWidget);
    expect(find.text('Por llegar (2)'), findsOneWidget);
    await tester.tap(find.text('Prueba #1'));
    await tester.pumpAndSettle();
    expect(find.text('Llegaron (1)'), findsOneWidget);
    expect(find.text('Sin ubicación (1)'), findsOneWidget);
    await tester.tap(find.text('Recibir 1'));
    await tester.pumpAndSettle();
    expect(db.ownedSkus(id), {'QTEST001'});
    expect(db.order(id, db.orders(id).single.id)!.received, isFalse);
    expect(db.skuLocations(id), isEmpty);

    await tester.tap(find.text('Marcar como recibido…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 ya estaba obtenido'), findsOneWidget);
    await tester.tap(find.byTooltip('Elegir ubicaciones'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bin 4'));
    await tester.pump();
    await tester.tap(find.text('Mostrar 1'));
    await tester.pumpAndSettle();
    final drag = await tester.startGesture(
      tester.getCenter(find.text('Prueba #2')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await drag.moveTo(tester.getCenter(find.text('Bin 4 (0)')));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(find.text('Bin 4 (1)'), findsOneWidget);
    await tester.tap(find.text('Recibir pedido'));
    await tester.pumpAndSettle();
    expect(db.ownedSkus(id), {'QTEST001', 'QTEST002'});
    expect(db.skuLocations(id), {'QTEST002': bin});
    // La próxima vez Bin 4 ya aparece a la vista.
    expect(db.getSetting('receive_locations_$id'), '$bin');
    expect(find.text('Volver a pendiente'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pedidos (0 pendientes)'));
    await tester.pumpAndSettle();
    expect(find.text('Recibidos'), findsOneWidget);
    expect(find.text('Panini México'), findsOneWidget);
  });

  testWidgets('almacenamiento: closet con bin y acomodar lo obtenido', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = AppDatabase.inMemory();
    db.upsertComics([
      for (var n = 1; n <= 2; n++)
        Comic(sku: 'QLOC00$n', name: 'Guardado #$n', number: n, price: 100),
    ]);
    final auth = AuthService(db)..register('tel', 'clave1234');
    final id = auth.currentUser!.id;
    db.setStatus(id, ['QLOC001', 'QLOC002'], ComicStatus.owned);
    await tester.pumpWidget(
      AppScope(db: db, auth: auth, child: const ComicsPaniniApp()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Almacén'));
    await tester.pumpAndSettle();
    expect(find.text('2 obtenidos sin ubicación.'), findsOneWidget);

    // Closet 1 y, dentro, Bin 4.
    await tester.tap(find.text('Nueva ubicación'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Closet 1');
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Opciones de la ubicación'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agregar dentro…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Bin 4');
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(db.locations(id).map((l) => l.path), [
      'Closet 1',
      'Closet 1 › Bin 4',
    ]);

    // Acomodar: elegir los dos y guardarlos en Bin 4.
    await tester.tap(find.text('Acomodar'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Guardado #1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Todos'));
    await tester.pumpAndSettle();
    expect(find.text('2 seleccionados'), findsOneWidget);
    await tester.tap(find.text('Guardar en…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bin 4'));
    await tester.pumpAndSettle();
    final bin = db.locations(id).last.id;
    expect(db.skuLocations(id), {'QLOC001': bin, 'QLOC002': bin});
    expect(find.text('Todos tus obtenidos tienen ubicación.'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('2 cómics'), findsOneWidget); // Bin 4
    expect(find.text('0 cómics · 2 con lo de adentro'), findsOneWidget);

    // La ficha muestra dónde está y deja sacarlo.
    await tester.tap(find.text('Bin 4'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Guardado #2'));
    await tester.pumpAndSettle();
    expect(find.text('Closet 1 › Bin 4'), findsWidgets);
    await tester.ensureVisible(find.byTooltip('Cambiar dónde está guardado'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cambiar dónde está guardado'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sin ubicación'));
    await tester.pumpAndSettle();
    expect(find.text('Sin ubicación · Guardar en…'), findsOneWidget);
    expect(db.skuLocations(id), {'QLOC001': bin});
  });

  testWidgets(
    'ordenar una ubicación arrastrando',
    (tester) async {
      tester.view.physicalSize = const Size(620, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final db = AppDatabase.inMemory();
      db.upsertComics([
        for (var n = 1; n <= 3; n++)
          Comic(sku: 'QORD00$n', name: 'Orden #$n', number: n, price: 100),
      ]);
      final auth = AuthService(db)..register('tel', 'clave1234');
      final id = auth.currentUser!.id;
      final bin = db.createLocation(id, 'Bin 4');
      db.setComicLocation(id, ['QORD001', 'QORD002', 'QORD003'], bin);
      List<String> order() =>
          db.locationItems(id, bin).map((i) => i.comic.sku).toList();

      await tester.pumpWidget(
        AppScope(db: db, auth: auth, child: const ComicsPaniniApp()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Almacén'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bin 4'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Ordenar'));
      await tester.pumpAndSettle();
      expect(find.text('Guardar cómics aquí'), findsNothing);

      Future<void> drag(String from, String to) async {
        final g = await tester.startGesture(tester.getCenter(find.text(from)));
        await tester.pump(const Duration(milliseconds: 300));
        await g.moveBy(const Offset(0, 30));
        await tester.pump();
        await g.moveTo(tester.getCenter(find.text(to).first));
        await tester.pump();
        await g.up();
        await tester.pumpAndSettle();
      }

      // El #3 pasa al frente.
      await drag('Orden #3', 'Orden #1');
      expect(order(), ['QORD003', 'QORD001', 'QORD002']);

      // Soltarlo en su propio lugar no cambia nada.
      await drag('Orden #1', 'Orden #1');
      expect(order(), ['QORD003', 'QORD001', 'QORD002']);

      await tester.tap(find.text('Listo'));
      await tester.pumpAndSettle();
      expect(find.text('Guardar cómics aquí'), findsOneWidget);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'ordenar: la cuadrícula se desplaza y deshacer respeta el lugar',
    (tester) async {
      tester.view.physicalSize = const Size(400, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final db = AppDatabase.inMemory();
      final skus = [for (var n = 10; n < 50; n++) 'QORD0$n'];
      db.upsertComics([
        for (final (i, sku) in skus.indexed)
          Comic(sku: sku, name: 'Largo #${i + 1}', number: i + 1, price: 100),
      ]);
      final auth = AuthService(db)..register('tel', 'clave1234');
      final id = auth.currentUser!.id;
      final bin = db.createLocation(id, 'Bin 4');
      db.setComicLocation(id, skus, bin);
      List<String> order() =>
          db.locationItems(id, bin).map((i) => i.comic.sku).toList();

      await tester.pumpWidget(
        AppScope(db: db, auth: auth, child: const ComicsPaniniApp()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Almacén'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bin 4'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Ordenar'));
      await tester.pumpAndSettle();

      // Se lleva el primero al fondo de la pantalla: su celda de origen sale de
      // pantalla y aun así se guarda al soltar.
      final g = await tester.startGesture(
        tester.getCenter(find.text('Largo #1')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await g.moveTo(const Offset(100, 845));
      await tester.pump();
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.text('Largo #2'), findsNothing);
      await g.moveTo(const Offset(100, 500));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      final moved = order();
      final at = moved.indexOf('QORD010');
      expect(at, greaterThan(4));
      expect(moved.first, 'QORD011');

      // Sacarlo y deshacer lo regresa a la misma posición.
      await tester.tap(find.text('Listo'));
      await tester.pumpAndSettle();
      final card = find.ancestor(
        of: find.text('Largo #1'),
        matching: find.byType(ComicStatusCard),
      );
      await tester.tap(
        find.descendant(of: card, matching: find.byTooltip('Más opciones')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Quitar de aquí'));
      await tester.pumpAndSettle();
      expect(order(), isNot(contains('QORD010')));
      await tester.tap(find.text('Deshacer'));
      await tester.pumpAndSettle();
      expect(order(), moved);
    },
  );

  testWidgets('datos recibidos sin sesión: se crea la cuenta y se importan', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // Lo que manda el otro dispositivo.
    final other = AppDatabase.inMemory();
    final u = other.insertUser('psych0o', 'h', 's');
    other.upsertComics([const Comic(sku: 'QBATM001', name: 'Batman #1')]);
    other.addToCollection(u, other.createCollection(u, 'Batman'), ['QBATM001']);
    other.setStatus(u, ['QBATM001'], ComicStatus.owned);
    final data = other.exportUserData(u, fullCatalog: true);

    final db = AppDatabase.inMemory();
    final auth = AuthService(db);
    await tester.pumpWidget(
      AppScope(db: db, auth: auth, child: const ComicsPaniniApp()),
    );
    expect(find.text('Recibir mis datos del teléfono'), findsOneWidget);

    Future<bool?> claim(void Function(User) onAuthenticated) =>
        showDialog<bool>(
          context: tester.element(find.byType(Scaffold).first),
          builder: (_) => ClaimAccountDialog(
            from: 'Teléfono de psych0o',
            summary: AppDatabase.inspectUserBackup(data),
            newComics: db.countNewComics(data),
            onAuthenticated: onAuthenticated,
          ),
        );

    final fields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextFormField),
    );
    final created = claim((user) => db.importUserData(user.id, data));
    await tester.pumpAndSettle();
    expect(find.text('Crear cuenta e importar'), findsOneWidget);
    // El usuario viene del respaldo; solo falta la contraseña.
    expect(
      tester.widget<TextFormField>(fields.at(0)).controller!.text,
      'psych0o',
    );
    await tester.enterText(fields.at(1), 'clave1234');
    await tester.enterText(fields.at(2), 'otra');
    await tester.tap(find.text('Crear cuenta e importar'));
    await tester.pump();
    expect(find.text('Las contraseñas no coinciden'), findsOneWidget);

    await tester.enterText(fields.at(2), 'clave1234');
    await tester.tap(find.text('Crear cuenta e importar'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(await created, isTrue);
    expect(auth.currentUser?.username, 'psych0o');
    expect(auth.isRemembered, isTrue);
    final me = auth.currentUser!.id;
    expect(db.collections(me).map((c) => c.name), ['Batman']);
    expect(db.statuses(me)['QBATM001'], ComicStatus.owned);

    // Si la cuenta ya existe, se pide su contraseña en lugar de crearla.
    auth.logout();
    await tester.pumpAndSettle();
    final again = claim((_) {});
    await tester.pumpAndSettle();
    expect(find.text('Entrar y reemplazar'), findsOneWidget);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(1), 'mala123');
    await tester.tap(find.text('Entrar y reemplazar'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(find.text('Usuario o contraseña incorrectos.'), findsOneWidget);
    await tester.tap(find.text('Rechazar'));
    await tester.pumpAndSettle();
    expect(await again, isFalse);
    expect(auth.isLoggedIn, isFalse);
  });

  testWidgets('el icono aparece y desaparece junto al nombre', (tester) async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final user = db.insertUser('psych0o', 'hash', 'sal');
    db.upsertComics([const Comic(sku: 'S1', name: 'Uno')]);
    db.markSynced(user);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SyncPendingIcon(db: db, userId: user, onPressed: () {}),
        ),
      ),
    );
    expect(find.byIcon(Icons.sync_problem), findsNothing);

    db.setStatus(user, ['S1'], ComicStatus.owned);
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.sync_problem), findsOneWidget);

    db.markSynced(user);
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.sync_problem), findsNothing);
  });
}
