require("dotenv").config();
const fs = require("fs");
const pool = require("../config/db");
const { normalizeVnText } = require("../utils/normalizeVnText");

// Bỏ tiền tố cấp hành chính để so khớp với normalized_name trong admin_boundaries.
function normalizeAdminPart(part) {
    return part.replace(/^(Phường|Xã|Thị trấn|Quận|Huyện)\s+/i, "").trim();
}

// parent_adm trong dữ liệu có thể bắt đầu bằng ấp/khu vực rồi mới đến phường,
// ví dụ "Đông Hiển A, Đông Thuận, Cần Thơ". Duyệt lần lượt các thành phần
// và chọn tên đầu tiên thực sự có trong admin_boundaries.
function findParentBoundary(parentAdm, boundaryIdByNormName) {
    if (!parentAdm) return null;

    for (const part of parentAdm.split(",")) {
        const candidate = normalizeAdminPart(part.trim());
        const parentId = boundaryIdByNormName.get(normalizeVnText(candidate));
        if (parentId) return { name: candidate, id: parentId };
    }

    return null;
}

// Một số dữ liệu cũ khai báo MultiPolygon nhưng coordinates lại có dạng Polygon:
//   Polygon:      [ring]
//   MultiPolygon: [[ring]]
// Chuẩn hóa thêm một cấp mảng để ST_GeomFromGeoJSON đọc đúng kiểu geometry.
function normalizeGeometry(geom) {
    if (!geom || !Array.isArray(geom.coordinates)) return geom;

    if (
        geom.type === "MultiPolygon" &&
        geom.coordinates.length > 0 &&
        Array.isArray(geom.coordinates[0]) &&
        Array.isArray(geom.coordinates[0][0]) &&
        typeof geom.coordinates[0][0][0] === "number"
    ) {
        return {
            ...geom,
            coordinates: [geom.coordinates],
        };
    }

    return geom;
}

async function run() {
    const filePath = process.argv[2];
    if (!filePath) {
        console.error("Cách dùng: node jobs/importPlaceGeometries.js <đường-dẫn-file.json>");
        process.exit(1);
    }

    const raw = fs.readFileSync(filePath, "utf8");
    let entries = JSON.parse(raw);
    if (!Array.isArray(entries)) entries = [entries]; // cho phép file chỉ có 1 object

    const { rows: boundaries } = await pool.query(`SELECT id, normalized_name FROM admin_boundaries`);
    const boundaryIdByNormName = new Map(boundaries.map((b) => [b.normalized_name, b.id]));

    let added = 0;
    let updated = 0;
    let conflicts = 0;
    let missingGeometry = 0;
    let skipped = 0;

    for (const entry of entries) {
        const parent = findParentBoundary(entry.parent_adm, boundaryIdByNormName);
        const wardName = parent?.name || null;
        const parentId = parent?.id || null;

        if (!parentId) {
            console.warn(
                `[importPlaceGeometries] Bỏ qua "${entry.name}": không tìm được parent_id cho "${wardName}"`
            );
            skipped++;
            continue;
        }

        try {
            const geometry = normalizeGeometry(entry.geom);

            // Geometry rỗng không thể vẽ trên map nên chỉ ghi nhận vào thống kê,
            // không tạo thêm một bản ghi rỗng trong database.
            if (
                !geometry ||
                !Array.isArray(geometry.coordinates) ||
                geometry.coordinates.length === 0
            ) {
                console.warn(`[importPlaceGeometries] Chưa có geometry: "${entry.name}"`);
                missingGeometry++;
                continue;
            }

            // Không tạo bản ghi trùng. Riêng bản ghi cũ có geometry rỗng sẽ được
            // cập nhật khi file import đã có geometry hợp lệ. ST_Force2D loại bỏ
            // trục Z vì cột geom của ứng dụng chỉ lưu geometry 2 chiều.
            const result = await pool.query(
                `
                INSERT INTO place_geometries(name, normalized_name, aliases, type, parent_id, geom)
                VALUES ($1, $2, $3, $4, $5,
                    ST_Force2D(ST_SetSRID(ST_Multi(ST_GeomFromGeoJSON($6)), 4326)))
                ON CONFLICT (normalized_name, parent_id) DO UPDATE SET
                    name = EXCLUDED.name,
                    aliases = EXCLUDED.aliases,
                    type = EXCLUDED.type,
                    geom = EXCLUDED.geom
                WHERE ST_IsEmpty(place_geometries.geom)
                  AND NOT ST_IsEmpty(EXCLUDED.geom)
                RETURNING (xmax = 0) AS inserted
                `,
                [
                    entry.name,
                    entry.normalized_name,
                    entry.aliases || [],
                    entry.type,
                    parentId,
                    JSON.stringify(geometry),
                ]
            );

            // ON CONFLICT có thể không thay đổi dòng nào, vì vậy phải dựa vào
            // rowCount thay vì tăng biến added sau mỗi câu query như trước đây.
            if (result.rowCount === 0) {
                console.log(`[importPlaceGeometries] Đã tồn tại, bỏ qua: "${entry.name}"`);
                conflicts++;
            } else if (result.rows[0].inserted) {
                console.log(`[importPlaceGeometries] Đã thêm: "${entry.name}" (parent_id=${parentId})`);
                added++;
            } else {
                console.log(`[importPlaceGeometries] Đã cập nhật geometry rỗng: "${entry.name}"`);
                updated++;
            }
        } catch (err) {
            console.error(`[importPlaceGeometries] Lỗi thêm "${entry.name}":`, err.message);
            skipped++;
        }
    }

    console.log(
        `\n[importPlaceGeometries] Hoàn tất: ${added} thêm, ${updated} cập nhật, ` +
        `${conflicts} đã tồn tại, ${missingGeometry} thiếu geometry, ${skipped} lỗi/bỏ qua`
    );
}

run()
    .then(() => pool.end())
    .catch((err) => {
        console.error(err);
        pool.end();
        process.exit(1);
    });
