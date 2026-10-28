import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models.dart';
import 'comic_widgets.dart';

/// Buscador del catálogo para elegir varios cómics. Devuelve los SKU elegidos
/// (null si se canceló). Los de [already] aparecen marcados y bloqueados.
Future<Set<String>?> pickComics(
  BuildContext context, {
  String title = 'Agregar cómics',
  Set<String> already = const {},
  String alreadyLabel = 'Ya está agregado',
}) => showDialog<Set<String>>(
  context: context,
  builder: (_) =>
      _ComicPicker(title: title, already: already, alreadyLabel: alreadyLabel),
);

class _ComicPicker extends StatefulWidget {
  const _ComicPicker({
    required this.title,
    required this.already,
    required this.alreadyLabel,
  });

  final String title;
  final Set<String> already;
  final String alreadyLabel;

  @override
  State<_ComicPicker> createState() => _ComicPickerState();
}

class _ComicPickerState extends State<_ComicPicker> {
  final _search = TextEditingController();
  final _selected = <String>{};
  List<Comic> _results = [];
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _runSearch();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _runSearch() {
    final db = AppScope.of(context).db;
    setState(() => _results = db.searchComics(query: _search.text, limit: 200));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 560,
        height: 520,
        child: Column(
          children: [
            TextField(
              controller: _search,
              autofocus: true,
              onChanged: (_) => _runSearch(),
              decoration: const InputDecoration(
                hintText: 'Buscar en el catálogo…',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: _results.length,
                itemBuilder: (context, i) {
                  final c = _results[i];
                  final already = widget.already.contains(c.sku);
                  return CheckboxListTile(
                    value: already || _selected.contains(c.sku),
                    onChanged: already
                        ? null
                        : (v) => setState(
                            () => v == true
                                ? _selected.add(c.sku)
                                : _selected.remove(c.sku),
                          ),
                    secondary: ComicCover(
                      url: c.imageUrl,
                      width: 32,
                      height: 48,
                    ),
                    title: Text(c.name),
                    subtitle: Text(
                      already
                          ? widget.alreadyLabel
                          : [
                              if (c.series != null) c.series!,
                              if (c.price != null) formatComicPrice(c),
                            ].join(' · '),
                    ),
                    dense: true,
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(context, Set.of(_selected)),
          child: Text('Agregar (${_selected.length})'),
        ),
      ],
    );
  }
}
