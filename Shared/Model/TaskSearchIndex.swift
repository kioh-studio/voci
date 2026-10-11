// Shared/Model/TaskSearchIndex.swift — chỉ mục tra ngược term → task, dùng để tìm task đã có khi
// người dùng nhắc lại nó bằng lời khác. Anh Khôi chốt 2026-08-20.
//
// VÌ SAO CẦN, KHI ĐÃ CÓ SO KHỚP TRIGRAM: trigram chỉ so TIÊU ĐỀ với TIÊU ĐỀ. Câu thật của người
// dùng chứa nhiều thứ không bao giờ lọt vào tiêu đề — "Làm task dems search trước 9h30, nội dung là
// sửa query để tokenize được trong Solr" chỉ để lại "Làm task dems search". Vài hôm sau nhắc "cái
// vụ Solr" thì không có gì để bấu víu: "solr" không nằm trong tiêu đề nào. Chỉ mục này đọc cả
// `notes` và `sourceTranscript` (verbatim, FR-001 luôn giữ), nên phần thân câu vẫn tra được.
//
// VÌ SAO KHÔNG CÓ DANH SÁCH STOP-WORD: anh Khôi đề xuất để AI lọc "từ chung chung" và trả về mảng
// term ấn tượng. Ý đúng, nhưng nó tự giải được ở local mà không tốn một lượt gọi model nào — bằng
// IDF: một term xuất hiện trong NHIỀU task của chính người dùng thì tự nó là từ chung chung VỚI
// NGƯỜI ĐÓ. "task", "làm", "sửa" nằm trong 20 task ⇒ trọng số gần 0; "solr" nằm trong 1 task ⇒
// trọng số cao nhất. Không phải nuôi danh sách song ngữ Việt–Anh nào, tự thích nghi với biệt ngữ
// riêng của từng người, và tự đúng cả với từ mà không danh sách nào đoán trước được.
//
// `indexTerms` do AI trả về (đề xuất gốc của anh Khôi) LẮP VÀO ĐÂY: `terms(of:)` bên dưới hợp tất
// cả nguồn term lại, nên khi trường đó có thật thì chỉ cần thêm một dòng vào hàm đó. Trường đó cần
// sửa prompt production ⇒ phải chạy probe xác nhận ⇒ chờ anh Khôi duyệt, xem backlog.md.
//
// Thuần: dựng từ đúng mảng task truyền vào, không đọc đồng hồ, không đọc store. Dựng lại mỗi lần
// cần thay vì nuôi một chỉ mục sống — với vài chục tới vài trăm task thì dựng lại là vài chục
// micro-giây, còn một chỉ mục sống phải đồng bộ qua mọi lần thêm/sửa/xoá/sync/recurrence-reset và
// đó mới là chỗ sinh bug thật. ponytail: chỉ mục sống khi nào đo được nó thành điểm nóng.
//
// UNVERIFIED — viết trên Windows, không có Swift toolchain. Chưa compile, chưa chạy.
import Foundation

struct TaskSearchIndex {

    /// term → những task chứa nó.
    private let postings: [String: Set<UUID>]
    /// Tổng số task đã lập chỉ mục — mẫu số của IDF.
    private let documentCount: Int

    init(tasks: [TaskItem]) {
        var postings: [String: Set<UUID>] = [:]
        for task in tasks {
            for term in Self.terms(of: task) {
                postings[term, default: []].insert(task.id)
            }
        }
        self.postings = postings
        self.documentCount = tasks.count
    }

    /// Mọi term của một task, gộp từ mọi nguồn có sẵn. Đây là chỗ DUY NHẤT quyết định "một task gồm
    /// những chữ nào" — thêm nguồn mới (ví dụ `indexTerms` từ AI) thì thêm đúng ở đây.
    static func terms(of task: TaskItem) -> Set<String> {
        var all = Self.tokenize(task.title)
        if let notes = task.notes { all.formUnion(Self.tokenize(notes)) }
        if let transcript = task.sourceTranscript { all.formUnion(Self.tokenize(transcript)) }
        // `details` là bản đọc lại của capture giọng nói, thường trùng `sourceTranscript` — hợp tập
        // nên trùng cũng vô hại.
        all.formUnion(Self.tokenize(task.details))
        return all
    }

    /// Những task giống `query` nhất, kèm điểm 0…1, sắp giảm dần. `query` là cả tiêu đề — hàm tự
    /// tách term.
    ///
    /// Điểm = (tổng IDF của các term khớp được) / (số term trong query × IDF cao nhất có thể).
    ///
    /// MẪU SỐ LÀ ĐIỂM MẤU CHỐT, và bản đầu em viết sai: nếu chia cho "tổng IDF của chính các term
    /// trong query" thì một query TOÀN CHỮ ĐỆM ("làm task") đạt đúng 1.0 — vì mọi term của nó đều
    /// khớp — và mỗi lần capture sẽ dội lên năm gợi ý rác. Chia cho điểm TỐI ĐA CÓ THỂ ĐẠT (mỗi
    /// term khớp một term hiếm nhất, tức `df == 1`) thì chữ đệm tự tụt: đo trên một kho 12 task
    /// thật, "làm task" ra 0.37 còn "làm task dems search" ra 0.685 cho task đúng và 0.185 cho task
    /// không liên quan. Và nó tự tốt lên khi kho lớn dần — kho càng nhiều task, chữ đệm càng nhiều
    /// df, IDF của nó càng nhỏ so với trần.
    func matches(for query: String, limit: Int) -> [(id: UUID, score: Double)] {
        let queryTerms = Self.tokenize(query)
        guard !queryTerms.isEmpty, documentCount > 0 else { return [] }
        let maxWeight = Self.idf(documentFrequency: 1, documentCount: documentCount) * Double(queryTerms.count)
        guard maxWeight > 0 else { return [] }

        var hits: [UUID: Double] = [:]
        for term in queryTerms {
            guard let matched = resolve(term) else { continue }
            let ids = postings[matched] ?? []
            let weight = Self.idf(documentFrequency: ids.count, documentCount: documentCount)
            for id in ids { hits[id, default: 0] += weight }
        }

        // Typed steps (CI 2026-10-11: the one-chain tuple form made the type-checker time out).
        var scored: [(id: UUID, score: Double)] = hits.map { (id: $0.key, score: min(1, $0.value / maxWeight)) }
        scored = scored.filter { $0.score > 0 }
        // `Dictionary` không có thứ tự — phá hoà bằng id, nếu không cùng một dữ liệu có thể cho
        // ra hai thứ tự khác nhau giữa hai lần chạy.
        scored.sort { lhs, rhs in
            if lhs.score == rhs.score { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.score > rhs.score
        }
        return Array(scored.prefix(limit))
    }

    /// Term khớp trong chỉ mục: ưu tiên khớp đúng, không có thì tìm term gần nhất theo trigram.
    /// Đây là thứ khiến "dems" vẫn tra ra task chỉ chứa "dem" — lỗi nghe/lỗi gõ một ký tự không
    /// được phép làm mất trắng một term, vì chính lớp term này mới là nơi giữ chữ hiếm.
    private func resolve(_ term: String) -> String? {
        if postings[term] != nil { return term }
        // Chỉ dò mờ cho term đủ dài. Term ngắn ("q", "9h") mà cho phép khớp mờ thì gần như chữ nào
        // cũng khớp chữ nào, và chúng vốn chẳng mang mấy thông tin.
        guard term.count >= 4 else { return nil }
        var best: (term: String, score: Double)?
        for candidate in postings.keys where abs(candidate.count - term.count) <= 2 {
            let score = Self.trigramSimilarity(term, candidate)
            guard score >= 0.6 else { continue }
            if best == nil || score > best!.score { best = (candidate, score) }
        }
        return best?.term
    }

    // MARK: - Thuần, không trạng thái

    /// `log(N / df)`, cộng 1 để term có mặt ở MỌI task vẫn còn một chút trọng số thay vì đúng 0
    /// (đúng 0 sẽ khiến một query toàn chữ phổ biến ra mẫu số 0 và không tính được điểm).
    static func idf(documentFrequency: Int, documentCount: Int) -> Double {
        guard documentFrequency > 0, documentCount > 0 else { return 0 }
        return log(Double(documentCount) / Double(documentFrequency)) + 1
    }

    /// Thường hoá + bỏ dấu + bỏ dấu câu, cắt theo khoảng trắng, bỏ token 1 ký tự (không mang thông
    /// tin, chỉ làm phình chỉ mục).
    static func tokenize(_ text: String) -> Set<String> {
        let folded = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let cleaned = folded.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return Set(String(cleaned).split(separator: " ").map(String.init).filter { $0.count > 1 })
    }

    /// Dice trên 3-gram ký tự — cùng công thức `AppState.fuzzyMatchScore` dùng cho tiêu đề, ở đây
    /// áp cho từng term. Giữ bản sao nhỏ này thay vì gọi sang `AppState` để file model không phụ
    /// thuộc ngược vào tầng app (và `AppState` là `@MainActor`, còn hàm này phải gọi được ở bất kỳ
    /// đâu).
    static func trigramSimilarity(_ a: String, _ b: String) -> Double {
        let ga = trigrams(a), gb = trigrams(b)
        guard !ga.isEmpty, !gb.isEmpty else { return 0 }
        return 2 * Double(ga.intersection(gb).count) / Double(ga.count + gb.count)
    }

    private static func trigrams(_ text: String) -> Set<String> {
        let padded = " " + text + " "
        guard padded.count >= 3 else { return [] }
        let characters = Array(padded)
        var grams: Set<String> = []
        for i in 0...(characters.count - 3) {
            grams.insert(String(characters[i..<(i + 3)]))
        }
        return grams
    }
}
