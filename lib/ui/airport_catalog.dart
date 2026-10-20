import 'service_catalog.dart';

class AirportCatalog extends ServiceCatalog {
  const AirportCatalog({
    super.key,
    required super.document,
    required super.items,
    required super.embedded,
    required super.loading,
    required super.collecting,
    required super.allLoaded,
    required super.onRefresh,
    required super.onCollect,
    required super.onStop,
    required super.onOpen,
    required super.actions,
    required super.footer,
    super.hasSnapshot,
    super.message,
    super.reference,
    super.initialError,
  }) : super(kind: ServiceCatalogKind.airport);
}
