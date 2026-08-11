import 'package:latlong2/latlong.dart';

class OutageDetailItem {
  final String? subareaName;
  final String? roadName;
  final String? powerCompany;
  final String areaText;
  final String? reason;
  final String? status;
  final String? startTime;
  final String? endTime;
  final String? source;
  final String? sourceUrl;

  OutageDetailItem({
    this.subareaName,
    this.roadName,
    this.powerCompany,
    required this.areaText,
    this.reason,
    this.status,
    this.startTime,
    this.endTime,
    this.source,
    this.sourceUrl,
  });

  factory OutageDetailItem.fromJson(Map<String, dynamic> json) {
    return OutageDetailItem(
      subareaName: json['subareaName'] as String?,
      roadName: json['roadName'] as String?,
      powerCompany: json['powerCompany'] as String?,
      areaText: json['areaText']?.toString() ?? '',
      reason: json['reason'] as String?,
      status: json['status'] as String?,
      startTime: json['startTime'] as String?,
      endTime: json['endTime'] as String?,
      source: json['source'] as String?,
      sourceUrl: json['sourceUrl'] as String?,
    );
  }

  String get timeRangeLabel {
    String trim(String? t) =>
        t != null && t.length >= 5 ? t.substring(0, 5) : (t ?? '?');
    return '${trim(startTime)} - ${trim(endTime)}';
  }
}

// Marker chấm tròn (ward centroid, district centroid, hoặc điểm cụ thể)
class OutagePointGroup {
  final String label;
  final double lat;
  final double lng;
  final String precision; // "point" | "ward" | "district"
  final List<OutageDetailItem> outages;

  OutagePointGroup({
    required this.label,
    required this.lat,
    required this.lng,
    required this.precision,
    required this.outages,
  });

  factory OutagePointGroup.fromJson(Map<String, dynamic> json) {
    final outagesJson = json['outages'] as List;
    return OutagePointGroup(
      label: json['label']?.toString() ?? '',
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      precision: json['precision']?.toString() ?? 'ward',
      outages: outagesJson
          .map((o) => OutageDetailItem.fromJson(o as Map<String, dynamic>))
          .toList(),
    );
  }
}

// Vùng tô màu của đường đã buffer.
class OutageAreaFeature {
  final String label;
  final String color; // "yellow" | "orange"
  final List<List<LatLng>> polygons;
  final OutageDetailItem outage;

  OutageAreaFeature({
    required this.label,
    required this.color,
    required this.polygons,
    required this.outage,
  });

  factory OutageAreaFeature.fromJson(Map<String, dynamic> json) {
    final geometry = json['geometry'] as Map<String, dynamic>;
    final type = geometry['type'] as String;
    final coords = geometry['coordinates'] as List? ?? [];

    List<List<LatLng>> polygons = [];

    if (type == 'Polygon') {
      if (coords.isNotEmpty) {
        polygons = [_ringToLatLng(coords.first as List)];
      }
    } else if (type == 'MultiPolygon') {
      polygons = coords
          .where((p) => (p as List).isNotEmpty)
          .map((p) => _ringToLatLng((p as List).first as List))
          .toList();
    }

    return OutageAreaFeature(
      label: json['label']?.toString() ?? '',
      color: json['color']?.toString() ?? 'yellow',
      polygons: polygons,
      outage: OutageDetailItem.fromJson(json['outage'] as Map<String, dynamic>),
    );
  }

  static List<LatLng> _ringToLatLng(List ring) {
    return ring
        .map((p) => LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble()))
        .toList();
  }
}
