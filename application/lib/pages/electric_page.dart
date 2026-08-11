import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import 'dart:math';
import '../models/BoundaryFeature.dart';
import '../models/OutageItem.dart';
import '../services/electric_services/boundary_api_service.dart';
import '../services/electric_services/outage_map_api_service.dart';
import '../services/location_service.dart';

class ElectricPage extends StatefulWidget {
  const ElectricPage({super.key});

  @override
  State<ElectricPage> createState() => _ElectricPageState();
}

class _ElectricPageState extends State<ElectricPage> {
  // Tọa độ và phạm vi mặc định dùng để giới hạn bản đồ trong khu vực Cần Thơ.
  static const LatLng canThoCenter = LatLng(10.0452, 105.7469);
  static final LatLngBounds canThoBounds = LatLngBounds(
    const LatLng(9.0, 100.4),
    const LatLng(10.4, 105.95),
  );

  // Ngưỡng zoom chuyển từ Phường sang Chi tiết
  // chỉnh lại số này sau khi test thực tế xem mức nào thấy rõ đường/khu vực.
  static const double detailZoomThreshold = 14.0;

  // Các controller và trạng thái tương tác trực tiếp với bản đồ.
  final MapController _mapController = MapController();
  final LocationService _locationService = LocationService();
  double _currentZoom = 12;
  bool _locating = false;

  // Dữ liệu được tách theo mức zoom để tránh hiển thị quá nhiều chi tiết cùng lúc.
  List<BoundaryFeature> _boundaries = [];
  List<OutagePointGroup> _wardSummaries = [];
  List<OutageAreaFeature> _roadAreas = [];
  List<OutagePointGroup> _fallbackPoints = [];

  // Trạng thái tải dữ liệu và thông tin dùng để phản hồi cho người dùng.
  bool _loading = true;
  bool _usingCachedData = false;
  String _outageDate = '';
  DateTime? _lastUpdated;
  String? _error;

  bool get _isDetailZoom => _currentZoom >= detailZoomThreshold;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  // Lấy dữ liệu hằng ngày; service sẽ lưu cache để có thể dùng khi offline.
  Future<void> _loadData() async {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());

    try {
      final boundariesFuture = BoundaryApiService.getAllBoundaries().then(
        (boundaries) => boundaries,
        onError: (_) => <BoundaryFeature>[],
      );
      final outageFuture = OutageMapApiService.getOutagesByWard(date: today);
      final outageResult = await outageFuture;

      // Ranh giới chỉ phục vụ bản đồ; danh sách/cache vẫn dùng được khi offline.
      final boundaries = await boundariesFuture;

      setState(() {
        _boundaries = boundaries;
        _wardSummaries = outageResult.wardSummaries;
        _roadAreas = outageResult.roadAreas;
        _fallbackPoints = outageResult.points;
        _outageDate = outageResult.date;
        _lastUpdated = outageResult.lastUpdated;
        _usingCachedData = outageResult.fromCache;
        _loading = false;
      });
    } catch (err) {
      setState(() {
        _error = err.toString();
        _loading = false;
      });
    }
  }

  // Sinh màu ổn định theo tên phường: cùng một tên luôn nhận cùng một màu.
  Color _colorForName(String name) {
    final hash = name.codeUnits.fold<int>(0, (prev, c) => prev + c);
    final random = Random(hash); //Hash để đảm bảo màu giống nhau mỗi khi mở app
    return Color.fromRGBO(
      100 + random.nextInt(155),
      100 + random.nextInt(155),
      100 + random.nextInt(155),
      1,
    );
  }

  // Mở danh sách chi tiết của một nhóm lịch cúp điện trên bản đồ.
  void _showOutageDetailsGroup(OutagePointGroup group) {
    _showOutageListSheet(group.label, group.outages);
  }

  // Mở chi tiết của một vùng đường hoặc địa điểm được người dùng chạm vào.
  void _showOutageDetailsSingle(String label, OutageDetailItem outage) {
    _showOutageListSheet(label, [outage]);
  }

  // Bottom sheet có thể kéo để người dùng xem nhiều lịch mà không rời bản đồ.
  void _showOutageListSheet(String title, List<OutageDetailItem> outages) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '$title (${outages.length} lịch cúp điện)',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    controller: scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: outages.length,
                    separatorBuilder: (_, __) => const Divider(height: 24),
                    itemBuilder: (context, index) =>
                        _OutageDetailTile(outage: outages[index]),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Thuật toán ray casting kiểm tra điểm chạm có nằm trong một vùng đa giác hay không.
  bool _pointInPolygon(LatLng point, List<LatLng> polygon) {
    bool inside = false;
    for (int i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final xi = polygon[i].longitude, yi = polygon[i].latitude;
      final xj = polygon[j].longitude, yj = polygon[j].latitude;
      final intersect =
          ((yi > point.latitude) != (yj > point.latitude)) &&
          (point.longitude <
              (xj - xi) * (point.latitude - yi) / (yj - yi) + xi);
      if (intersect) inside = !inside;
    }
    return inside;
  }

  // Chỉ kiểm tra vùng cúp điện khi zoom gần để hạn chế phép tính không cần thiết.
  void _handleMapTap(LatLng point) {
    if (!_isDetailZoom) return;

    for (final area in _roadAreas) {
      for (final ring in area.polygons) {
        if (_pointInPolygon(point, ring)) {
          _showOutageDetailsSingle(area.label, area.outage);
          return;
        }
      }
    }
  }

  // Xin quyền vị trí (nếu cần) rồi đưa bản đồ về tọa độ hiện tại của người dùng.
  Future<void> _moveToCurrentLocation() async {
    if (_locating) return;

    setState(() => _locating = true);
    try {
      final position = await _locationService.getCurrentLocation();
      if (!mounted) return;

      _mapController.move(LatLng(position.latitude, position.longitude), 16);
    } catch (error) {
      if (!mounted) return;
      final message = error.toString().replaceFirst('Exception: ', '');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          if (!_usingCachedData)
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: canThoCenter,
                initialZoom: 12,
                minZoom: 8,
                maxZoom: 18,
                cameraConstraint: CameraConstraint.contain(
                  bounds: canThoBounds,
                ),
                onMapEvent: (event) {
                  final newZoom = event.camera.zoom;
                  if ((newZoom - _currentZoom).abs() > 0.05) {
                    setState(() => _currentZoom = newZoom);
                  }
                },
                onTap: (tapPosition, point) => _handleMapTap(point),
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      "https://basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png",
                ),

                // Luôn giữ lớp phân vùng hành chính từ admin_boundaries.
                // Khi zoom sâu, vùng đường được vẽ đè lên lớp này ở phía dưới.
                PolygonLayer(
                  polygons: _boundaries.expand((feature) {
                    final color = _colorForName(feature.name);
                    return feature.polygons.map(
                      (ring) => Polygon(
                        points: ring,
                        color: color.withOpacity(0.4),
                        borderColor: color,
                        borderStrokeWidth: 1.5,
                        label: _currentZoom >= 11 ? feature.name : null,
                      ),
                    );
                  }).toList(),
                ),

                // --- ZOOM SÂU: tô vàng/cam các tuyến đường ---
                if (_isDetailZoom)
                  PolygonLayer(
                    polygons: _roadAreas.expand((area) {
                      final fillColor = area.color == 'yellow'
                          ? Colors.amber
                          : Colors.deepOrange;
                      return area.polygons.map(
                        (ring) => Polygon(
                          points: ring,
                          color: fillColor.withOpacity(0.5),
                          borderColor: fillColor,
                          borderStrokeWidth: 1.5,
                        ),
                      );
                    }).toList(),
                  ),

                // --- ZOOM XA: 1 marker gộp cho mỗi phường ---
                if (!_isDetailZoom)
                  MarkerLayer(
                    markers: _wardSummaries.map((group) {
                      return Marker(
                        point: LatLng(group.lat, group.lng),
                        width: 44,
                        height: 44,
                        child: GestureDetector(
                          onTap: () => _showOutageDetailsGroup(group),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              const Icon(
                                Icons.bolt,
                                color: Colors.red,
                                size: 32,
                                shadows: [
                                  Shadow(color: Colors.black45, blurRadius: 4),
                                ],
                              ),
                              Positioned(
                                top: 0,
                                right: 0,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.red,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    '${group.outages.length}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),

                // --- ZOOM SÂU: marker fallback cho outage chưa match đường ---
                if (_isDetailZoom)
                  MarkerLayer(
                    markers: _fallbackPoints.map((group) {
                      return Marker(
                        point: LatLng(group.lat, group.lng),
                        width: 36,
                        height: 36,
                        child: GestureDetector(
                          onTap: () => _showOutageDetailsGroup(group),
                          child: const Icon(
                            Icons.bolt,
                            color: Colors.orange,
                            size: 28,
                            shadows: [
                              Shadow(color: Colors.black45, blurRadius: 4),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
              ],
            ),
          // Khi offline, dữ liệu cache vẫn được trình bày trong bảng lịch phía trên.
          if (_usingCachedData)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.grey.shade100,
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.cloud_off, size: 48, color: Colors.grey),
                      SizedBox(height: 8),
                      Text('Đang hiển thị lịch đã lưu trên thiết bị'),
                    ],
                  ),
                ),
              ),
            ),
          // Bảng tổng hợp lịch trong ngày luôn nổi phía trên bản đồ.
          if (!_loading && _error == null)
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: _DailyOutagePanel(
                groups: _wardSummaries,
                date: _outageDate,
                lastUpdated: _lastUpdated,
                fromCache: _usingCachedData,
              ),
            ),
          if (_loading) const Center(child: CircularProgressIndicator()),
          if (_error != null)
            Positioned(
              bottom: 20,
              left: 20,
              right: 20,
              child: Material(
                color: Colors.red.shade100,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('Lỗi tải dữ liệu: $_error'),
                ),
              ),
            ),
          if (!_usingCachedData)
            Positioned(
              right: 16,
              bottom: 16,
              //Nút ấn về vị trí hiện tại
              child: FloatingActionButton.small(
                heroTag: 'current-location',
                tooltip: 'Về vị trí hiện tại',
                onPressed: _locating ? null : _moveToCurrentLocation,
                child: _locating
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.my_location),
              ),
            ),
        ],
      ),
    );
  }
}

// Bảng tổng hợp lịch cúp điện hằng ngày theo từng phường.
class _DailyOutagePanel extends StatelessWidget {
  final List<OutagePointGroup> groups;
  final String date;
  final DateTime? lastUpdated;
  final bool fromCache;

  const _DailyOutagePanel({
    required this.groups,
    required this.date,
    required this.lastUpdated,
    required this.fromCache,
  });

  // Tổng số lịch của tất cả phường, dùng cho nhãn tóm tắt của bảng.
  int get outageCount =>
      groups.fold(0, (total, group) => total + group.outages.length);

  // Chuẩn hóa ngày từ API sang định dạng quen thuộc với người dùng Việt Nam.
  String get displayDate {
    final parsedDate = DateTime.tryParse(date);
    return parsedDate == null
        ? date
        : DateFormat('dd/MM/yyyy').format(parsedDate);
  }

  @override
  Widget build(BuildContext context) {
    final updateLabel = lastUpdated == null
        ? null
        : DateFormat('HH:mm dd/MM/yyyy').format(lastUpdated!.toLocal());

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      elevation: 3,
      child: ExpansionTile(
        leading: const Icon(Icons.electrical_services, color: Colors.orange),
        title: Text(
          'Lịch cúp điện hôm nay ($outageCount)',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          fromCache
              ? 'Ngoại tuyến • Dữ liệu ngày $displayDate'
              : 'Dữ liệu ngày $displayDate',
        ),
        children: [
          if (updateLabel != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Cập nhật lần cuối: $updateLabel',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          const Divider(height: 1),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.5,
            ),
            child: groups.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Không có lịch cúp điện trong ngày này.'),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: groups.length,
                    itemBuilder: (context, index) {
                      final group = groups[index];
                      return ExpansionTile(
                        title: Text(group.label),
                        subtitle: Text('${group.outages.length} lịch cúp điện'),
                        children: group.outages
                            .map(
                              (outage) => Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  4,
                                  16,
                                  16,
                                ),
                                child: _OutageDetailTile(outage: outage),
                              ),
                            )
                            .toList(),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _OutageDetailTile extends StatelessWidget {
  // Một dòng chi tiết dùng chung cho bảng lịch và bottom sheet trên bản đồ.
  final OutageDetailItem outage;

  const _OutageDetailTile({required this.outage});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.access_time, size: 16, color: Colors.grey),
            const SizedBox(width: 4),
            Text(
              outage.timeRangeLabel,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            if (outage.status != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  outage.status!,
                  style: TextStyle(fontSize: 12, color: Colors.blue.shade700),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(outage.areaText, style: const TextStyle(fontSize: 14)),
        if (outage.reason != null) ...[
          const SizedBox(height: 4),
          Text(
            'Lý do: ${outage.reason}',
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ],
        if (outage.powerCompany != null) ...[
          const SizedBox(height: 2),
          Text(
            outage.powerCompany!,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
        if (outage.source != null) ...[
          const SizedBox(height: 4),
          Text(
            'Nguồn: ${_sourceLabel(outage.source!)}',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
        if (outage.sourceUrl != null && outage.sourceUrl!.isNotEmpty) ...[
          const SizedBox(height: 2),
          SelectableText(
            outage.sourceUrl!,
            style: const TextStyle(fontSize: 12, color: Colors.blue),
          ),
        ],
      ],
    );
  }

  static String _sourceLabel(String source) {
    switch (source) {
      case 'lichcupdien_org':
        return 'Lịch Cúp Điện';
      case 'vietnambiz_com':
        return 'VietnamBiz';
      case 'xemlichcatdien_com':
        return 'Xem Lịch Cắt Điện';
      default:
        return source;
    }
  }
}
