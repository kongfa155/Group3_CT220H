const sources = require("../config/sources");
const { fetchLichcupdienOrg } = require("./fetchers/lichcupdienOrgFetcher");
const { fetchVietnambiz } = require("./fetchers/vietnambizFetcher");
const { fetchXemlichcatdien } = require("./fetchers/xemlichcatdienFetcher");

//File thực hiện gọi tất cả các file fetch và chuẩn hóa tụi nó về cùng 1 cấu trúc để thực hiện gửi cho AI không bị lỗi
async function fetchAllSources() {
    const chunks = [];

    // --- lichcupdien.org ---
    try {
        const { chunks: orgChunks, fallbackFullText } = await fetchLichcupdienOrg();
        if (fallbackFullText) {
            chunks.push({
                source: "lichcupdien_org",
                sourceUrl: sources.lichcupdien_org.url,
                districtHint: null,
                rawText: fallbackFullText,
                coverage: sources.lichcupdien_org.coverage,
            });
        } else {
            for (const text of orgChunks) {
                chunks.push({
                    source: "lichcupdien_org",
                    sourceUrl: sources.lichcupdien_org.url,
                    districtHint: null,
                    rawText: text,
                    coverage: sources.lichcupdien_org.coverage,
                });
            }
        }
    } catch (err) {
        console.error("[sourceFetcher] Lỗi fetch lichcupdien_org:", err.message);
    }

    // --- vietnambiz.vn (bài báo mới nhất, tìm qua trang danh mục) ---
    try {
            const articles = await fetchVietnambiz(); // Bây giờ trả về một mảng

            for (const article of articles) {
                chunks.push({
                    source: "vietnambiz_com",
                    sourceUrl: article.articleUrl,
                    districtHint: null,
                    rawText: article.text,
                    coverage: sources.vietnambiz_com.coverage,
                });
                console.log(`[sourceFetcher] vietnambiz_com: lấy thành công từ bài "${article.articleUrl}"`);
            }
        } catch (err) {
            console.error("[sourceFetcher] Lỗi fetch vietnambiz_com:", err.message);
        }

    // --- xemlichcatdien.com (chỉ có dữ liệu hôm nay) ---
    try {
        const { text } = await fetchXemlichcatdien();
        chunks.push({
            source: "xemlichcatdien_com",
            sourceUrl: sources.xemlichcatdien_com.url,
            districtHint: null,
            rawText: text,
            coverage: sources.xemlichcatdien_com.coverage,
        });
    } catch (err) {
        console.error("[sourceFetcher] Lỗi fetch xemlichcatdien_com:", err.message);
    }

    return chunks;
}

module.exports = { fetchAllSources };
