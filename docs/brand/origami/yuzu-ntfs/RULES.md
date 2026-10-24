# Quy tắc tài sản · Yuzu NTFS

## Danh tính và quyết định

- Sản phẩm: **Yuzu NTFS**; chức năng: Đọc/ghi ổ NTFS (Windows) trên Mac, tự mount, tự chuyển chỉ-đọc khi ổ không an toàn · macOS 26+.
- `slug`: `yuzu-ntfs`; `family`: `icon-hero`.
- Phương án (`option`): `C` — Ổ đĩa + khiên · nền đồi/mây.
- Ý tưởng: Đọc ra ổ cứng ngay nhờ cổng cắm. Khiên coral nói đúng tính năng an toàn (tự chuyển chỉ-đọc). Ảnh xám vẫn rõ. Nền: đồi + mây đều hai bên, cân đối.
- Trạng thái (`status`): `proposed`.
- Duyệt: `proposed` — không dùng phát hành.
- Chỉ `approved` được phát hành; có sẵn bản xuất **không** đồng nghĩa đã duyệt.

## Đơn vị sử dụng và tệp

Sao chép **toàn bộ thư mục này**, giữ `RULES.md`, `style.lock.json`, `meta.json` bên cạnh ảnh và bản xuất.
Không cần tài liệu ở thư mục gốc để hiểu hợp đồng này. Đây là tài sản Blue Coral cho sản phẩm được chỉ định,
không phải ảnh công cộng: chỉ dùng trong dự án được cho phép; không bán lại, cấp phép lại hoặc đưa lên kho ảnh.

| Tệp tương đối trong thư mục này | Mục đích |
| --- | --- |
| `master.png` | Nguồn PNG gốc bất biến; đầu vào duy nhất khi xuất lại. |
| `icon.webp` | Ảnh xem nhanh; không dùng làm nguồn xuất tài sản. |
| `meta.json` | Danh tính, quyết định duyệt, nguồn, lời nhắc và mã băm. |
| `RULES.md` | Quy tắc độc lập phải đi cùng toàn bộ thư mục. |
| `style.lock.json` | Bản khóa phong cách tại lúc thêm; bản đã duyệt không tự cập nhật. |
| `export/ios/AppIcon.appiconset/AppIcon-1024.png` | Bản xuất tự động cho nền tảng ghi trong đường dẫn. |
| `export/ios/AppIcon.appiconset/Contents.json` | Bảng kê tài sản; mọi tên ảnh phải tồn tại trong cùng bộ. |
| `export/macos/AppIcon-1024.png` | Bản xuất tự động cho nền tảng ghi trong đường dẫn. |
| `export/macos/AppIcon.appiconset/Contents.json` | Bảng kê tài sản; mọi tên ảnh phải tồn tại trong cùng bộ. |
| `export/macos/AppIcon.appiconset/icon_128x128.png` | Bản xuất tự động cho nền tảng ghi trong đường dẫn. |
| `export/macos/AppIcon.appiconset/icon_128x128@2x.png` | Bản xuất tự động cho nền tảng ghi trong đường dẫn. |
| `export/macos/AppIcon.appiconset/icon_16x16.png` | Bản xuất tự động cho nền tảng ghi trong đường dẫn. |
| `export/macos/AppIcon.appiconset/icon_16x16@2x.png` | Bản xuất tự động cho nền tảng ghi trong đường dẫn. |
| `export/macos/AppIcon.appiconset/icon_256x256.png` | Bản xuất tự động cho nền tảng ghi trong đường dẫn. |
| `export/macos/AppIcon.appiconset/icon_256x256@2x.png` | Bản xuất tự động cho nền tảng ghi trong đường dẫn. |
| `export/macos/AppIcon.appiconset/icon_32x32.png` | Bản xuất tự động cho nền tảng ghi trong đường dẫn. |
| `export/macos/AppIcon.appiconset/icon_32x32@2x.png` | Bản xuất tự động cho nền tảng ghi trong đường dẫn. |
| `export/macos/AppIcon.appiconset/icon_512x512.png` | Bản xuất tự động cho nền tảng ghi trong đường dẫn. |
| `export/macos/AppIcon.appiconset/icon_512x512@2x.png` | Bản xuất tự động cho nền tảng ghi trong đường dẫn. |
| `export/macos/AppIcon.icns` | Bản xuất tự động cho nền tảng ghi trong đường dẫn. |
| `export/preview.png` | Ảnh đối chiếu, không đưa vào ứng dụng. |
| `options/yuzu-ntfs-a-yuzu-core-drive-bg.webp` | Phương án tham khảo chưa duyệt; không dùng phát hành. |
| `options/yuzu-ntfs-b-two-way-drive-bg.webp` | Phương án tham khảo chưa duyệt; không dùng phát hành. |

`SHA-256` của `master.png`: `7f1e4db41ed5b9480532a6aebe46e6f949066b983cb8252ce9929f6badaa53a2`.

## Tích hợp

| Nền tảng | Nguồn trong thư mục này → nơi đặt |
| --- | --- |
| Xcode iOS | `export/ios/AppIcon.appiconset` → `Assets.xcassets/AppIcon.appiconset` của target iOS. |
| Xcode macOS | `export/macos/AppIcon.appiconset` → `Assets.xcassets/AppIcon.appiconset` của target macOS. |
| Flutter iOS | `export/ios/AppIcon.appiconset` → `ios/Runner/Assets.xcassets/AppIcon.appiconset`. |
| Flutter macOS | `export/macos/AppIcon.appiconset` → `macos/Runner/Assets.xcassets/AppIcon.appiconset`. |
| Ứng dụng macOS khác | `export/macos/AppIcon.icns` → cấu hình đóng gói nhận `.icns`. |
| Web | Tạo favicon/PWA từ master đã duyệt theo framework; thư mục này chưa có favicon/PWA. Không dùng PNG macOS có khoảng lùi làm favicon. |

Thay nguyên bộ `AppIcon.appiconset`, không trộn `Contents.json` và PNG từ hai lần xuất.
iOS: PNG 1024 vuông, RGB không alpha, hệ điều hành tự tạo mặt nạ. macOS: RGBA 1024 có alpha,
hình 824×824 ở giữa, góc liên tục và bóng mềm do bộ xuất chuẩn tạo; không tự sửa.
`export/preview.png` chỉ để xem. Kiểm tra cấu hình `AppIcon` của target khi tích hợp.

## Điều phải giữ và điều cấm

- Không chỉnh tay bất kỳ `export` nào; không dùng WebP làm `master`, không nén mất dữ liệu PNG.
- Không sinh lại (`re-generate`) hoặc ghi đè `master.png`. Muốn thiết kế khác phải mở vòng mới,
  dùng `option`/mã phương án mới, giữ nguyên PNG và lời nhắc cũ; chỉ thay lựa chọn sau quyết định chủ sở hữu.
  CLI từ chối sửa tài sản `approved` tại chỗ; không hạ trạng thái để lách khóa.
- Không đổi màu (`recolour`), cắt (`crop`), uốn (`warp`), ghép hoặc bo góc (`round corners`) vào ảnh gốc/bản xuất.
  Mặt nạ macOS do bộ xuất chuẩn thực hiện, không phải ngoại lệ cho chỉnh tay.
- Mã nền (`backdrop`) `#B5CCFF` được dành riêng cho sản phẩm này; mọi option cùng sản phẩm giữ mã này, sản phẩm khác không chiếm dụng.
- Chỉ lựa chọn `approved` mới được phát hành; các ảnh trong `options/` vẫn chưa duyệt.
- Cấm chữ, logo, giao diện đọc được, dấu chìm, người/tay/mặt, kim loại vàng/viền vàng,
  nhựa bóng, đồ chơi CGI, viền vẽ, tô màu hoạt hình; cấm nền lấn át giấy, nguồn sáng thứ hai,
  nền tối bão hòa kiểu icon vòng 1 và đổi góc nhìn icon sang từ trên xuống/chính diện.
- Không cam kết số lượng chính xác hoặc đồng nhất từng điểm ảnh từ AI khi chưa có bằng chứng.

## Bản chụp phong cách đã khóa

- Phiên bản thư viện (`library_version`): `self-contained-v1`.
- Bảng màu (`palette`): `cobalt` `#2B4BFF`, `coral` `#FF5A4E`, `pearl` `#F4F1EA`, `navy` `#0B1433`, `yuzu` `#FFC93C`, `sky` `#8DB4FF`.
- Nền (`backdrop`): `#B5CCFF`.
- `icon-hero` (r3): nền pastel rõ màu, một vật thể chính rộng 66–74% khung, tối đa 1 chi tiết phụ gắn vào hero; vùng an toàn giữa 86%; góc nhìn 3/4 khoảng 30°; đọc được ở 16 px.
- Chất liệu: giấy washi mờ, có thớ, độ dày và nếp gấp sắc; mặt giấy phân biệt bằng sáng/tối,
  không viền vẽ, không bóng nhựa. Ảnh tham chiếu chỉ quy định chất liệu, không sao chép vật thể.
- Ánh sáng: duy nhất trên-trái, bóng xuống-phải; icon sáng dịu, cảnh tối có một tia trong sương nhẹ.
  Viền coral trong cảnh tối là phản xạ cùng nguồn sáng, không phải đèn thứ hai.
- Các khối lời nhắc (`prompt blocks`) nguyên bản của dòng hình tại lúc thêm:

```json
{
  "STYLE": "Square 1024x1024 app-icon artwork, full-bleed: no rounded corners, no border, no phone or device mockup (the operating system applies the icon mask later). Bright, airy, high-key studio photograph of ONE handcrafted origami object folded from matte washi-like paper: visible paper fibre, crisp creases, facets defined only by light and shade. A bold, simple, iconic object, not a diorama. No outlines, no gold, no gloss, no plastic, no cel shading, no CGI look, not a flat vector, not a line icon.",
  "BACKGROUND": "BACKGROUND: light and cheerful, never dark, never a flat plain colour: a clearly coloured pastel paper backdrop ({bg}) with a soft daylight gradient (lighter towards the upper-left), plus a SIMPLE paper landscape far behind the hero exactly in the spirit of the approved family icons: 2 gentle layered paper hills along the lower background and 1 or 2 large soft paper clouds higher up, all cut from paper in lighter and slightly deeper tints of the backdrop colour, softly out of focus, low contrast. Optionally one small pale yuzu-yellow paper sun disc near the upper-left corner. These background shapes give depth only: they stay behind the hero, never overlap its silhouette edges heavily, carry no saturated cobalt or coral, and never compete with the hero.",
  "COMPOSITION": "COMPOSITION: ONE single hero origami object that carries the product meaning, about 66-74% of the canvas width, centred with its optical centre slightly low, standing on the backdrop with one soft contact shadow. A bold, simple silhouette that is instantly recognisable at 16 px and in greyscale: few large clean paper planes, no fussy small folds. At most ONE small supporting element, no larger than 12% of the canvas, physically attached to or resting against the hero. Everything inside the central 86% safe zone, nothing cropped. No scattered props, no confetti, no clutter, no tiny specks.",
  "VIEW": "VIEW: three-quarter view, camera about 30 degrees above the table plane, the same viewpoint for every icon in this family (not a flat lay, not straight-on).",
  "LIGHT": "LIGHT: soft bright daylight from out of frame at the upper-left, high-key exposure, gentle soft shadows falling to the lower-right. Every icon of this family uses exactly this light.",
  "COLOUR": "COLOUR: Blue Coral origami palette: cobalt #2B4BFF, coral #FF5A4E, pearl white #F4F1EA, deep navy #0B1433 (tiny accents only), yuzu yellow #FFC93C, sky blue #8DB4FF. The hero uses 2 or 3 of these paper colours in large clear blocks, and at least one large block contrasts strongly with the backdrop {bg}; the hero never uses the backdrop colour. Matte, joyful, eye-catching, not glossy.",
  "REF": "Attached image 1 defines ONLY the paper material and crease quality (matte washi fibre, cobalt/coral/white facets). IGNORE its dark room and dramatic beam: this family is bright and high-key. Do not copy its shape, room, props or composition.",
  "NEVER": "NEVER: text, letters, digits, currency signs, logos, brand marks (no Windows four-pane logo, no Apple logo, no USB symbol), UI, readable screens, watermark, people, hands, faces. Paper documents, notes and menu cards stay blank. Exception: a simple mathematical symbol shape such as '=' or '+' built from folded paper strips is allowed only when the HERO description explicitly asks for it.",
  "AVOID": "Round 1 was rejected as monotonous: never a dark or saturated flat background; the backdrop stays a light pastel. Round 3 with a plain single-colour backdrop was rejected by the owner: always include the soft paper hills and clouds behind. Round 2 is too busy at small sizes: no scattered foreground props around the hero, no confetti; the background landscape stays soft and simple."
}
```

Những lệch phong cách cần tránh (ghi nguyên văn theo bản khóa):
- Round 1 was rejected as “đơn điệu”: one isolated object on a dark/saturated flat background. Do not return to this icon treatment.
- Gold-leaf edging from Careers v3 is DROPPED. No metallic gold, rims or drawn outlines. Matte yuzu yellow paper is allowed for icons only.
- No glossy plastic, CGI-toy sheen, cel shading, text, logos, readable UI, faces or hands.
- No top-down flat-lay or straight-on icon camera drift.
- Do not let bright sky, table, props or background outshine the origami.
- At 29–40 px the supporting details can become noise; disclose this and offer a separately reviewed reduced hero-only derivative if needed.
- Material changes need a NEW PHOTOGRAPH, NOT AN EDIT; conservative image edits tend to retain the old glossy material.

`style.lock.json` chứa cả bảng màu, các khối lời nhắc, nền, lời nhắc ảnh và mã băm.
Khi đã `approved`, chạy `catalog`/`export` không thay bản khóa theo công thức mới.

## Xuất lại và kiểm tra

Chạy từ thư viện gốc **đã checkout đúng commit đã pin**, không chạy từ bản sao thư mục đơn:

```bash
python3 scripts/library.py export --product-slug yuzu-ntfs
python3 scripts/library.py verify --product-slug yuzu-ntfs
```

Lệnh export chỉ tái xuất từ PNG đã lưu, không sinh ảnh mới.
`verify` kiểm tra tệp bắt buộc, `SHA-256` khớp meta/bản khóa, ảnh được `Contents.json` tham chiếu,
kích thước/alpha của ảnh 1024 iOS/macOS và trạng thái trong quy tắc; lỗi trả mã khác 0.
Ghi lệnh, đầu ra kiểm tra và commit nguồn vào PR tích hợp; sau đó sao chép nguyên thư mục.
Bản sao độc lập kiểm tra ít nhất mã băm bằng `shasum -a 256 master.png` và đối chiếu mã ở trên.

## Bắt buộc cập nhật thư viện khi phát sinh hoặc đổi icon

Mọi repo dùng bluecoral-origami, khi phát sinh icon mới hoặc cập nhật icon (phương án mới, duyệt, đổi trạng thái), phải thêm/cập nhật vào thư viện này qua `library.py add-icon` rồi `library.py catalog` để cập nhật `icons/icons.html` tại /Users/rom/Projects/bluecoral-origami/icons, chạy `verify`, commit + push PR/commit ở bluecoral-origami; không giữ icon chỉ trong repo đích.

Thực hiện đúng thứ tự sau tại repo thư viện; thay thông tin `example-app`/đường dẫn bằng
tài sản thực, giữ lại mọi `--option-webp`/`--option-note` hiện có. Khi owner duyệt,
dùng `--status approved --approved-on YYYY-MM-DD --approved-by 'owner (Blue Coral)'`
thay `--status proposed`; không tự duyệt hoặc sửa master đã duyệt.

```bash
cd /Users/rom/Projects/bluecoral-origami
python3 scripts/library.py add-icon --product-slug example-app --product 'Example App' \
  --master /path/to/option-a.png --status proposed --option A \
  --option-name-vn 'Tên phương án' --concept-vn 'Ý tưởng bằng tiếng Việt' \
  --role-vn 'Chức năng sản phẩm' --backdrop '#E5F4DF' --platforms ios,macos \
  --prompt-file '/path/to/_prompts.json#example-app-a' \
  --source-repo my-project --source-round 2026-10-23-r1 \
  --source-file review/r1/raw/example-app-a.png
python3 scripts/library.py catalog
python3 scripts/library.py verify
git add icons/ scenes/ catalog.json index.html
git commit -m "Update example-app icon and generated gallery"
git push origin HEAD
```

## Nguồn gốc và revision phải pin

- Kho nguồn (`source repo`): `bluecoral-origami`.
- Vòng (`source round`): `2026-10-24-yuzu-r3b`.
- Tệp nguồn (`source file`): `out/2026-10-24-yuzu-r3b/raw/yuzu-ntfs-c-safe-drive-bg.png`.
- Commit thư viện lúc chụp phong cách: `a85ed4ba576477582bf514a6c35599f5457e0e09`.
- Khi lấy tài sản, pin **commit chứa nguyên thư mục đang sao chép**, không pin nhánh trôi.
  Trong bản checkout nguồn chạy `git rev-parse HEAD`, ghi đủ SHA vào dự án đích.
  Commit lúc chụp ở trên là nguồn công thức, không thay thế commit chứa lần cập nhật tài sản.

## Lời nhắc nguyên văn

Nội dung dưới đây giữ nguyên từng ký tự của `prompt` trong `meta.json`/`style.lock.json`:

```text
Square 1024x1024 app-icon artwork, full-bleed: no rounded corners, no border, no phone or device mockup (the operating system applies the icon mask later). Bright, airy, high-key studio photograph of ONE handcrafted origami object folded from matte washi-like paper: visible paper fibre, crisp creases, facets defined only by light and shade. A bold, simple, iconic object, not a diorama. No outlines, no gold, no gloss, no plastic, no cel shading, no CGI look, not a flat vector, not a line icon.

BACKGROUND: light and cheerful, never dark, never a flat plain colour: a clearly coloured pastel paper backdrop (#B5CCFF) with a soft daylight gradient (lighter towards the upper-left), plus a SIMPLE paper landscape far behind the hero exactly in the spirit of the approved family icons: 2 gentle layered paper hills along the lower background and 1 or 2 large soft paper clouds higher up, all cut from paper in lighter and slightly deeper tints of the backdrop colour, softly out of focus, low contrast. Optionally one small pale yuzu-yellow paper sun disc near the upper-left corner. These background shapes give depth only: they stay behind the hero, never overlap its silhouette edges heavily, carry no saturated cobalt or coral, and never compete with the hero.

COMPOSITION: ONE single hero origami object that carries the product meaning, about 66-74% of the canvas width, centred with its optical centre slightly low, standing on the backdrop with one soft contact shadow. A bold, simple silhouette that is instantly recognisable at 16 px and in greyscale: few large clean paper planes, no fussy small folds. At most ONE small supporting element, no larger than 12% of the canvas, physically attached to or resting against the hero. Everything inside the central 86% safe zone, nothing cropped. No scattered props, no confetti, no clutter, no tiny specks.

VIEW: three-quarter view, camera about 30 degrees above the table plane, the same viewpoint for every icon in this family (not a flat lay, not straight-on).

HERO: a chunky cobalt folded paper portable external hard drive in three-quarter view

SUPPORTING ELEMENT (optional, at most one): a pearl-white folded paper shield with a coral centre facet leaning against the front right side of the drive (data safety)

FAMILY MARK: one small matte yuzu-yellow #FFC93C folded paper yuzu leaf resting on top of the drive; it is the only yellow element and stays small

LIGHT: soft bright daylight from out of frame at the upper-left, high-key exposure, gentle soft shadows falling to the lower-right. Every icon of this family uses exactly this light.

COLOUR: Blue Coral origami palette: cobalt #2B4BFF, coral #FF5A4E, pearl white #F4F1EA, deep navy #0B1433 (tiny accents only), yuzu yellow #FFC93C, sky blue #8DB4FF. The hero uses 2 or 3 of these paper colours in large clear blocks, and at least one large block contrasts strongly with the backdrop #B5CCFF; the hero never uses the backdrop colour. Matte, joyful, eye-catching, not glossy.

Attached image 1 defines ONLY the paper material and crease quality (matte washi fibre, cobalt/coral/white facets). IGNORE its dark room and dramatic beam: this family is bright and high-key. Do not copy its shape, room, props or composition.

NEVER: text, letters, digits, currency signs, logos, brand marks (no Windows four-pane logo, no Apple logo, no USB symbol), UI, readable screens, watermark, people, hands, faces. Paper documents, notes and menu cards stay blank. Exception: a simple mathematical symbol shape such as '=' or '+' built from folded paper strips is allowed only when the HERO description explicitly asks for it.

Additional attached references define family/composition only; preserve the requested subject, camera and light. Do not copy text or logos.

KEEP: Attached image 2 is this exact icon from the previous round: keep its HERO object (shape, folds, colours, size, position, supporting element and yuzu-yellow mark) as close as possible, but REPLACE its plain single-colour backdrop. Attached image 3 is an approved icon of this family: copy ONLY its background treatment (soft layered pastel paper hills low behind, large pale paper clouds higher up, gentle depth), never its fruit, document, arrow, leaves or any other object. Use the backdrop colour requested below, not the colour of image 3.

AVOID: Round 1 was rejected as monotonous: never a dark or saturated flat background; the backdrop stays a light pastel. Round 3 with a plain single-colour backdrop was rejected by the owner: always include the soft paper hills and clouds behind. Round 2 is too busy at small sizes: no scattered foreground props around the hero, no confetti; the background landscape stays soft and simple. Gold-leaf edging from Careers v3 is DROPPED. No metallic gold, rims or drawn outlines. Matte yuzu yellow paper is allowed for icons only. No glossy plastic, CGI-toy sheen, cel shading, text, logos, readable UI, faces or hands. No top-down flat-lay or straight-on icon camera drift. Do not let bright sky, table, props or background outshine the origami.

Use your image generation tool to create exactly ONE image. Save it into the current working directory as yuzu-ntfs-c-safe-drive-bg.png and print its absolute path. Do not create any other files and do not post-process the image with code.
```
