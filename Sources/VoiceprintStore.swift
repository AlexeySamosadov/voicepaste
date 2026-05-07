import Foundation

struct Voiceprint: Codable, Identifiable {
    let id: UUID
    var name: String
    /// 256-d L2-normalized embedding (WeSpeaker via FluidAudio).
    var embedding: [Float]
    /// Cosine threshold for accepting a match against this profile.
    /// Default 0.55 — tune per-profile via UI later.
    var threshold: Float
    var enrolledAt: Date

    init(id: UUID = UUID(), name: String, embedding: [Float],
         threshold: Float = 0.55, enrolledAt: Date = Date()) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.threshold = threshold
        self.enrolledAt = enrolledAt
    }

    // Forward-compat: tolerate missing/extra fields and accept both ISO 8601
    // strings and numeric (seconds-since-reference-date) for `enrolledAt`.
    // Previous bug: save used .iso8601 but load used the default decoder
    // (deferredToDate, which expects a number). Decode would fail silently and
    // the catch branch wiped profiles to []. This made all enrolled profiles
    // vanish on every app relaunch.
    enum CodingKeys: String, CodingKey {
        case id, name, embedding, threshold, enrolledAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name = (try? c.decode(String.self, forKey: .name)) ?? "Unnamed"
        self.embedding = (try? c.decode([Float].self, forKey: .embedding)) ?? []
        self.threshold = (try? c.decode(Float.self, forKey: .threshold)) ?? 0.55

        // Try ISO 8601 string, then numeric seconds, then default to now.
        if let s = try? c.decode(String.self, forKey: .enrolledAt) {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) {
                self.enrolledAt = d
            } else {
                let f2 = ISO8601DateFormatter()
                f2.formatOptions = [.withInternetDateTime]
                self.enrolledAt = f2.date(from: s) ?? Date()
            }
        } else if let n = try? c.decode(Double.self, forKey: .enrolledAt) {
            self.enrolledAt = Date(timeIntervalSinceReferenceDate: n)
        } else {
            self.enrolledAt = Date()
        }
    }
}

/// Persistent store for enrolled voice profiles.
final class VoiceprintStore: ObservableObject {
    @Published private(set) var profiles: [Voiceprint] = []

    static let storePath: URL = {
        Config.configDir.appendingPathComponent("voiceprints.json")
    }()

    init() {
        load()
    }

    func load() {
        let path = VoiceprintStore.storePath
        guard let data = try? Data(contentsOf: path) else {
            print("[VoiceprintStore] No file at \(path.path). Starting empty.")
            profiles = []
            return
        }
        do {
            // Match save format: ISO 8601 dates. The custom Voiceprint
            // init(from:) also tolerates both formats for forward-compat.
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            profiles = try decoder.decode([Voiceprint].self, from: data)
            print("[VoiceprintStore] Loaded \(profiles.count) voiceprint(s) from \(path.path)")
        } catch {
            // Don't silently wipe! Backup the file the user spent time enrolling
            // and start empty. The user can recover by restoring the .bak file.
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let bakPath = path.deletingLastPathComponent()
                .appendingPathComponent("voiceprints.json.bak.\(fmt.string(from: Date()))")
            try? FileManager.default.copyItem(at: path, to: bakPath)
            print("[VoiceprintStore] Decode error: \(error). Backed up to \(bakPath.lastPathComponent), starting empty.")
            profiles = []
        }
    }

    func save() {
        let path = VoiceprintStore.storePath
        do {
            try FileManager.default.createDirectory(
                at: Config.configDir, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(profiles)
            // Atomic write so a crash mid-save can't truncate the file to 0 bytes.
            try data.write(to: path, options: .atomic)
            print("[VoiceprintStore] Saved \(profiles.count) voiceprint(s) to \(path.path)")
        } catch {
            print("[VoiceprintStore] save error: \(error)")
        }
    }

    func add(_ profile: Voiceprint) {
        profiles.append(profile)
        save()
    }

    func remove(id: UUID) {
        profiles.removeAll { $0.id == id }
        save()
    }

    func update(_ profile: Voiceprint) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
            save()
        }
    }

    /// Returns the highest-similarity profile (regardless of threshold).
    /// Caller decides whether the score meets that profile's threshold.
    func bestMatch(_ embedding: [Float]) -> (profile: Voiceprint, similarity: Float)? {
        guard !profiles.isEmpty else { return nil }
        var best: (Voiceprint, Float) = (profiles[0], -.infinity)
        for p in profiles {
            let sim = VoiceprintStore.cosine(embedding, p.embedding)
            if sim > best.1 { best = (p, sim) }
        }
        return best
    }

    /// Returns true if the embedding matches ANY profile (sim ≥ that profile's threshold).
    func anyMatch(_ embedding: [Float]) -> (profile: Voiceprint, similarity: Float)? {
        var best: (Voiceprint, Float)?
        for p in profiles {
            let sim = VoiceprintStore.cosine(embedding, p.embedding)
            if sim >= p.threshold {
                if best == nil || sim > best!.1 { best = (p, sim) }
            }
        }
        return best
    }

    /// Append-and-renormalize: blend `newEmbedding` into the profile's stored
    /// embedding (running mean) and re-normalize. Used by "Should have passed?"
    /// online learning.
    func mergeIntoProfile(id: UUID, newEmbedding: [Float], weight: Float = 0.25) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        let old = profiles[idx].embedding
        guard old.count == newEmbedding.count else { return }
        var merged = [Float](repeating: 0, count: old.count)
        for i in 0..<old.count {
            merged[i] = (1 - weight) * old[i] + weight * newEmbedding[i]
        }
        profiles[idx].embedding = VoiceprintStore.l2Normalize(merged)
        save()
    }

    // MARK: - math

    /// Cosine similarity for L2-normalized vectors == dot product.
    /// Falls through to full cosine for non-normalized inputs.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? dot / denom : -1
    }

    static func l2Normalize(_ v: [Float]) -> [Float] {
        var n: Float = 0
        for x in v { n += x * x }
        n = n.squareRoot()
        guard n > 0 else { return v }
        return v.map { $0 / n }
    }

    /// Mean of N embeddings, then L2-normalized — used during enrollment.
    static func meanEmbedding(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        var acc = [Float](repeating: 0, count: first.count)
        for emb in embeddings {
            guard emb.count == first.count else { continue }
            for i in 0..<first.count { acc[i] += emb[i] }
        }
        let n = Float(embeddings.count)
        for i in 0..<acc.count { acc[i] /= n }
        return l2Normalize(acc)
    }
}
