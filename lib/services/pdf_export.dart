import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../app_scope.dart';
import '../models.dart';
import '../widgets/comic_widgets.dart';
import 'cover_cache.dart';
import 'currency.dart';

/// La fuente estándar del PDF (Helvetica) solo trae caracteres latinos
/// (Windows-1252). Lo demás se cambia por "?" para que no falle.
String pdfSafe(String text) {
  final out = StringBuffer();
  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    try {
      latin1.encode(ch);
      out.write(ch);
    } catch (_) {
      const extra = '€‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ';
      out.write(extra.contains(ch) ? ch : '?');
    }
  }
  return out.toString();
}

/// Monto en la moneda elegida sin el código, para las columnas.
String _money(double? v) => v == null
    ? ''
    : formatPrice(v).replaceAll(' ${Money.instance.display}', '');

String _availability(Comic c) => [
  if (c.isPreorder()) 'Preventa',
  if (c.hasStockInfo) c.inStock ? 'Disponible' : 'Agotado',
].join(' / ');

PdfColor _pdfColor(Color c) => PdfColor(c.r, c.g, c.b);

/// Arma el PDF de una lista de cómics. [covers] son las portadas ya
/// preparadas (PNG pequeños) por SKU; si es null, no lleva portadas.
Future<Uint8List> buildComicsPdf({
  required String title,
  required String username,
  required List<CollectionItem> items,
  Map<String, Uint8List>? covers,
  DateTime? now,
}) {
  final date = now ?? DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp = '${two(date.day)}/${two(date.month)}/${date.year}';

  const sum = sumValue;
  final owned = items.where((i) => i.status == ComicStatus.owned);
  final purchased = items.where((i) => i.status == ComicStatus.purchased);
  final missing = items.where(
    (i) => i.status != ComicStatus.owned && i.status != ComicStatus.purchased,
  );

  final red = _pdfColor(ownedColor);
  const grey = PdfColor.fromInt(0xFF666666);
  final headerStyle = pw.TextStyle(
    fontWeight: pw.FontWeight.bold,
    color: PdfColors.white,
    fontSize: 9,
  );
  const cell = pw.TextStyle(fontSize: 9);
  final withCovers = covers != null;

  pw.Widget pad(pw.Widget child) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
    child: child,
  );

  final doc = pw.Document(
    title: pdfSafe('ComicShelf - $title'),
    author: pdfSafe(username),
    creator: 'ComicShelf',
  );
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.letter,
      margin: const pw.EdgeInsets.all(32),
      header: (context) => context.pageNumber == 1
          ? pw.SizedBox()
          : pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 8),
              child: pw.Text(
                pdfSafe('ComicShelf - $title'),
                style: const pw.TextStyle(color: grey, fontSize: 9),
              ),
            ),
      footer: (context) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            pdfSafe('$username · $stamp'),
            style: const pw.TextStyle(color: grey, fontSize: 8),
          ),
          pw.Text(
            'Página ${context.pageNumber} de ${context.pagesCount}',
            style: const pw.TextStyle(color: grey, fontSize: 8),
          ),
        ],
      ),
      build: (context) => [
        pw.Text(
          'ComicShelf',
          style: pw.TextStyle(color: red, fontWeight: pw.FontWeight.bold),
        ),
        pw.Text(
          pdfSafe(title),
          style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 6),
        pw.Text(
          '${items.length} cómics · Total ${formatPrice(sum(items))}',
          style: const pw.TextStyle(fontSize: 11),
        ),
        pw.Text(
          'Obtenidos ${owned.length} (${_money(sum(owned))}) · '
          'Comprados ${purchased.length} (${_money(sum(purchased))}) · '
          'Faltan ${missing.length} (${_money(sum(missing))})',
          style: const pw.TextStyle(fontSize: 10, color: grey),
        ),
        pw.SizedBox(height: 12),
        pw.Table(
          border: const pw.TableBorder(
            horizontalInside: pw.BorderSide(
              color: PdfColor.fromInt(0xFFDDDDDD),
              width: 0.5,
            ),
          ),
          columnWidths: {
            if (withCovers) 0: const pw.FixedColumnWidth(34),
            (withCovers ? 1 : 0): const pw.FixedColumnWidth(18),
            (withCovers ? 2 : 1): const pw.FlexColumnWidth(),
            (withCovers ? 3 : 2): const pw.FixedColumnWidth(70),
            (withCovers ? 4 : 3): const pw.FixedColumnWidth(100),
            (withCovers ? 5 : 4): const pw.FixedColumnWidth(60),
          },
          defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
          children: [
            pw.TableRow(
              decoration: pw.BoxDecoration(color: red),
              repeat: true,
              children: [
                if (withCovers) pad(pw.SizedBox()),
                pad(pw.Text('', style: headerStyle)),
                pad(pw.Text('Cómic', style: headerStyle)),
                pad(pw.Text('Estado', style: headerStyle)),
                pad(pw.Text('Disponibilidad', style: headerStyle)),
                pad(
                  pw.Text(
                    'Precio',
                    style: headerStyle,
                    textAlign: pw.TextAlign.right,
                  ),
                ),
              ],
            ),
            for (final (n, item) in items.indexed)
              pw.TableRow(
                children: [
                  if (withCovers)
                    pad(
                      covers[item.comic.sku] == null
                          ? pw.SizedBox(width: 26, height: 40)
                          : pw.Image(
                              pw.MemoryImage(covers[item.comic.sku]!),
                              width: 26,
                              height: 40,
                              fit: pw.BoxFit.cover,
                            ),
                    ),
                  // Casilla: llena si ya lo tienes; vacía para palomear a mano.
                  pad(
                    pw.Container(
                      width: 9,
                      height: 9,
                      decoration: pw.BoxDecoration(
                        color: item.status == ComicStatus.owned ? red : null,
                        border: pw.Border.all(color: grey, width: 0.8),
                      ),
                    ),
                  ),
                  pad(
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          pdfSafe(item.comic.name),
                          style: cell.copyWith(fontWeight: pw.FontWeight.bold),
                        ),
                        pw.Text(
                          pdfSafe(
                            [
                              item.comic.sku,
                              if (item.comic.releaseDate != null)
                                item.comic.releaseDate!,
                            ].join(' · '),
                          ),
                          style: const pw.TextStyle(fontSize: 7, color: grey),
                        ),
                      ],
                    ),
                  ),
                  pad(pw.Text(item.status.label, style: cell)),
                  pad(pw.Text(_availability(item.comic), style: cell)),
                  pad(
                    pw.Text(
                      pdfSafe(formatComicPrice(item.comic))
                          .replaceAll(' ${Money.instance.display}', ''),
                      style: cell,
                      textAlign: pw.TextAlign.right,
                    ),
                  ),
                ],
                decoration: n.isOdd
                    ? const pw.BoxDecoration(
                        color: PdfColor.fromInt(0xFFF5F5F5),
                      )
                    : null,
              ),
          ],
        ),
      ],
    ),
  );
  return doc.save();
}

/// Portadas pequeñas en PNG (el PDF no acepta WebP). Usa las guardadas en
/// el dispositivo; las que no estén y no se puedan bajar quedan en blanco.
Future<Map<String, Uint8List>> pdfCovers(List<CollectionItem> items) async {
  final cache = CoverCache.instance;
  final covers = <String, Uint8List>{};
  if (cache == null) return covers;
  for (final item in items) {
    final url = item.comic.imageUrl;
    if (url == null) continue;
    try {
      final bytes = await cache.load(url);
      if (bytes == null) continue;
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 78);
      final frame = await codec.getNextFrame();
      final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      if (png != null) covers[item.comic.sku] = png.buffer.asUint8List();
    } catch (_) {}
  }
  return covers;
}

/// Nombre de archivo a partir del título.
String _fileName(String title) {
  final slug = title
      .toLowerCase()
      .replaceAll(RegExp('[áàä]'), 'a')
      .replaceAll(RegExp('[éèë]'), 'e')
      .replaceAll(RegExp('[íìï]'), 'i')
      .replaceAll(RegExp('[óòö]'), 'o')
      .replaceAll(RegExp('[úùü]'), 'u')
      .replaceAll('ñ', 'n')
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return 'comicshelf_${slug.isEmpty ? 'lista' : slug}.pdf';
}

/// Arma el PDF (con portadas) y lo guarda donde elija el usuario.
Future<void> exportComicsPdf(
  BuildContext context, {
  required String title,
  required List<CollectionItem> items,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final username = AppScope.of(context).user.username;
  if (items.isEmpty) {
    showNotice(messenger, 'No hay cómics para exportar.');
    return;
  }
  showNotice(messenger, 'Preparando PDF de ${items.length} cómics…');
  try {
    final bytes = await buildComicsPdf(
      title: title,
      username: username,
      items: items,
      covers: await pdfCovers(items),
    );
    final saved = await FilePicker.saveFile(
      dialogTitle: 'Guardar PDF',
      fileName: _fileName(title),
      bytes: bytes,
      mimeType: 'application/pdf',
    );
    messenger.hideCurrentSnackBar();
    if (saved == null) return;
    final where = saved.scheme == 'file'
        ? saved.toFilePath()
        : saved.toString();
    showNotice(messenger, 'PDF guardado en $where');
  } catch (e) {
    showNotice(messenger, 'No se pudo crear el PDF: $e');
  }
}
