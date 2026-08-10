const pool = require("../config/db");
const { normalizeVnText, normalizeRoadKey } = require("../utils/normalizeVnText");
const { extractDistrictHint } = require("../utils/extractDistrictHint");

const WARD_LEVEL_TYPES = new Set(["Phường", "Xã", "Thị trấn"]);
const DISTRICT_LEVEL_TYPE = "Quận/Huyện";
const ROAD_BUFFER_METERS = 10;

// GeoJSON có coordinates rỗng vẫn là object hợp lệ trong JavaScript nhưng
// Flutter không thể vẽ nó, vì vậy không được xem place này là đã match.
function hasUsableGeometry(geometry) {
    return !!(
        geometry &&
        Array.isArray(geometry.coordinates) &&
        geometry.coordinates.length > 0
    );
}

// Tên khu vực từ nguồn lịch điện không thống nhất: "KV Long Thạnh 2",
// "Khu vực Long Thạnh 2" và "Long Thạnh 2" có thể cùng chỉ một nơi.
function placeLookupKeys(name) {
    const normalized = normalizeVnText(name)
        .replace(/[;,]+/g, " ")
        .replace(/\s+/g, " ")
        .trim();
    if (!normalized) return [];

    const withoutPartial = normalized.replace(/^mot phan\s+/, "").trim();
    const withoutAreaPrefix = withoutPartial
        .replace(/^(?:khu vuc|kv|phuong|xa|thi tran)\s+/, "")
        .trim();

    return [...new Set([normalized, withoutPartial, withoutAreaPrefix].filter(Boolean))];
}

// Trích ward ra khỏi parent_name dạng "Tân An, Cần Thơ" hoặc
// "An Thới, Bình Thủy, Cần Thơ" -> lấy phần đầu tiên ("Tân An"/"An Thới").
function extractWardFromParentName(parentName) {
    if (!parentName) return null;
    return parentName.split(",")[0].trim();
}

exports.getOutagesByWard = async (req, res) => {
    try {
        const date = req.query.date || new Date().toISOString().slice(0, 10);

        const { rows: outageRows } = await pool.query(
            `
            SELECT
                s.ward_name, s.subarea_name, s.road_name, s.extraction_result,
                r.power_company, r.area_text, r.reason, r.status,
                r.outage_date, r.start_time, r.end_time
            FROM electric_outages_staging s
            JOIN electric_outages_raw r ON r.id = s.raw_id
            WHERE r.outage_date = $1
            `,
            [date]
        );

        const [{ rows: roadRows }, { rows: placeRows }, { rows: boundaryRows }] = await Promise.all([
            // Buffer sẵn 10m mỗi bên NGAY TRONG QUERY - tính 1 lần cho mỗi
            // đường (không phải mỗi outage), đỡ tốn CPU lặp lại. Lấy thêm
            // parent_name để phân biệt các đường trùng tên khác phường
            // (VD "30/4" ở Tân An khác "30/4" ở Ninh Kiều).
            pool.query(
                `SELECT normalized_name, parent_name,
                        ST_AsGeoJSON(ST_Buffer(geom::geography, $1)::geometry) AS buffered_geojson
                 FROM road_segments`,
                [ROAD_BUFFER_METERS]
            ),
            pool.query(`SELECT normalized_name, aliases, ST_AsGeoJSON(geom) AS geojson FROM place_geometries`),
            pool.query(
                `SELECT id, name, normalized_name, type,
                        ST_AsGeoJSON(ST_Centroid(geom)) AS centroid_geojson
                 FROM admin_boundaries`
            ),
        ]);

        // roadByCompositeKey: key = "tênđường|phường" - match chính xác khi
        // biết cả ward_name của outage lẫn parent_name của đường.
        // roadByNameOnly: fallback khi không đủ thông tin ward để match
        // composite (giữ lại bản ghi ĐẦU TIÊN gặp - không đại diện chính
        // xác 100% khi có nhiều đoạn trùng tên khác phường).
        const roadByCompositeKey = new Map();
        const roadByNameOnly = new Map();

        for (const r of roadRows) {
            const roadKey = normalizeRoadKey(r.normalized_name);
            const wardKey = normalizeVnText(extractWardFromParentName(r.parent_name));
            const geometry = JSON.parse(r.buffered_geojson);

             //Check nếu road chưa có tọa độ thì không gửi lên
             if (
                    !geometry ||
                    !geometry.coordinates ||
                    geometry.coordinates.length === 0
                ) {
                    console.warn("Road geometry rỗng:", r.normalized_name);
                    continue;
                }

            roadByCompositeKey.set(`${roadKey}|${wardKey}`, geometry);

            if (!roadByNameOnly.has(roadKey)) {
                roadByNameOnly.set(roadKey, geometry);
            }
        }

        const placeByNormName = new Map();
        for (const place of placeRows) {
            const geometry = place.geojson ? JSON.parse(place.geojson) : null;

            // Không đưa geometry rỗng vào index. Nếu không, object GeoJSON vẫn
            // truthy và outage bị coi là đã match, trong khi Flutter không có
            // polygon nào để vẽ và cũng không nhận được marker fallback.
            if (!hasUsableGeometry(geometry)) continue;

            const names = [place.normalized_name, ...(place.aliases || [])];
            for (const name of names) {
                for (const key of placeLookupKeys(name)) {
                    // Ưu tiên bản ghi hợp lệ đầu tiên nếu alias bị trùng.
                    if (!placeByNormName.has(key)) {
                        placeByNormName.set(key, geometry);
                    }
                }
            }
        }

        const wardByNormName = new Map();
        const districtByNormName = new Map();
        for (const b of boundaryRows) {
            const centroid = JSON.parse(b.centroid_geojson);
            const entry = { id: b.id, name: b.name, lat: centroid.coordinates[1], lng: centroid.coordinates[0] };
            if (WARD_LEVEL_TYPES.has(b.type)) wardByNormName.set(b.normalized_name, entry);
            else if (b.type === DISTRICT_LEVEL_TYPE) districtByNormName.set(b.normalized_name, entry);
        }

        const roadAreas = [];
        const placeAreas = [];
        const fallbackPoints = new Map(); // dùng khi zoom sâu nhưng không có road/place cụ thể
        const wardSummaries = new Map(); // dùng khi zoom xa - marker gộp cả phường

        for (const row of outageRows) {
            const outagePayload = {
                subareaName: row.subarea_name,
                roadName: row.road_name,
                powerCompany: row.power_company,
                areaText: row.area_text,
                reason: row.reason,
                status: row.status,
                startTime: row.start_time,
                endTime: row.end_time,
            };

            // --- Xác định phường/quận để GỘP VÀO wardSummaries -----------
            // Luôn làm bước này cho MỌI outage, kể cả outage đã match được
            // road/place cụ thể - vì marker tổng hợp cấp phường (lúc zoom xa)
            // cần liệt kê TẤT CẢ outage trong phường đó, không chỉ phần
            // "chưa xác định vị trí".
            let boundary = row.ward_name ? wardByNormName.get(normalizeVnText(row.ward_name)) : null;
            if (!boundary) {
                const districtHint = extractDistrictHint(row.power_company);
                if (districtHint) boundary = districtByNormName.get(normalizeVnText(districtHint));
            }

            if (boundary) {
                const key = `ward:${boundary.id}`;
                if (!wardSummaries.has(key)) {
                    wardSummaries.set(key, {
                        boundaryId: boundary.id,
                        label: boundary.name,
                        lat: boundary.lat,
                        lng: boundary.lng,
                        outages: [],
                    });
                }
                wardSummaries.get(key).outages.push(outagePayload);
            } else {
                console.warn(`[outageMapController] Không xác định được ward cho: "${row.area_text}"`);
            }

            // --- Xác định hiển thị CHI TIẾT (dùng khi zoom sâu) ----------
            // Đọc TOÀN BỘ mảng streets[] trong extraction_result (JSONB đã
            // có sẵn), thay vì chỉ đọc road_name (chỉ lưu 1 đường đầu tiên).
            // Với outage nhiều đường (VD khu trung tâm cắt điện đồng loạt),
            // vòng lặp này giúp tô màu TẤT CẢ đường đã có trong road_segments,
            // không chỉ 1 đường đại diện.
            const extraction = row.extraction_result || {};
            const streetList = Array.isArray(extraction.streets) && extraction.streets.length > 0
                ? extraction.streets
                : (row.road_name ? [row.road_name] : []);

            let matchedAnyRoad = false;
            const wardKeyForOutage = normalizeVnText(row.ward_name);

            for (const streetName of streetList) {
                const roadKey = normalizeRoadKey(streetName);

                // Ưu tiên match chính xác theo cả tên đường + phường - tránh
                // nhầm giữa các đường trùng tên khác phường (VD "30/4").
                let geometry = row.ward_name
                    ? roadByCompositeKey.get(`${roadKey}|${wardKeyForOutage}`)
                    : null;

                // Không có ward_name hoặc không match composite -> fallback
                // theo tên thôi (có thể chọn nhầm đoạn nếu trùng tên khác
                // phường, nhưng vẫn hiển thị được thay vì bỏ trắng).
                if (!geometry) {
                    geometry = roadByNameOnly.get(roadKey);
                }

                if (geometry) {
                    const isPartial = !!(extraction.from_landmark || extraction.to_landmark);
                    roadAreas.push({
                        geometry,
                        color: isPartial ? "orange" : "yellow",
                        label: streetName,
                        outage: outagePayload,
                    });
                    matchedAnyRoad = true;
                }
            }

            if (matchedAnyRoad) continue;

            // Một outage cấp xã/phường thường có subarea_name = null (ví dụ
            // "Xã Trung Hưng"). Trong trường hợp đó vẫn thử ward_name để tận
            // dụng polygon đã import trong place_geometries.
            const placeName = row.subarea_name || row.ward_name;
            if (placeName) {
                const geometry = placeLookupKeys(placeName)
                    .map((key) => placeByNormName.get(key))
                    .find(hasUsableGeometry);
                if (geometry) {
                    placeAreas.push({
                        geometry,
                        color: "yellow",
                        label: placeName,
                        outage: outagePayload,
                    });
                    continue;
                }
            }

            // --- Không match road/place cụ thể -> fallback điểm centroid -
            if (boundary) {
                const key = `point:${boundary.id}`;
                if (!fallbackPoints.has(key)) {
                    fallbackPoints.set(key, {
                        label: boundary.name,
                        lat: boundary.lat,
                        lng: boundary.lng,
                        outages: [],
                    });
                }
                fallbackPoints.get(key).outages.push(outagePayload);
            }
        }

        res.json({
            date,
            wardSummaries: [...wardSummaries.values()], // dùng khi ZOOM XA
            roadAreas, // dùng khi ZOOM SÂU
            placeAreas, // dùng khi ZOOM SÂU
            points: [...fallbackPoints.values()], // dùng khi ZOOM SÂU (fallback)
        });
    } catch (err) {
        console.error(err);
        res.status(500).json({ message: err.message });
    }
};
