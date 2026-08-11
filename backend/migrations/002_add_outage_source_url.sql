-- Chạy migration này trước khi khởi động phiên bản backend có trả nguồn trích dẫn.
ALTER TABLE electric_outages_raw
    ADD COLUMN IF NOT EXISTS source_url TEXT;

-- Bổ sung URL cho dữ liệu cũ; bản ghi VietnamBiz mới sẽ lưu URL bài cụ thể.
UPDATE electric_outages_raw
SET source_url = CASE source
    WHEN 'lichcupdien_org' THEN 'https://lichcupdien.org/lich-cup-dien-can-tho'
    WHEN 'vietnambiz_com' THEN 'https://vietnambiz.vn/lich-cup-dien-can-tho.html'
    WHEN 'xemlichcatdien_com' THEN 'https://xemlichcatdien.com/lich-cup-dien-can-tho/'
    ELSE source_url
END
WHERE source_url IS NULL;
