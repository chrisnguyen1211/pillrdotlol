import Foundation

/// `GET /api/v1/models`, LM Studio's own listing, recorded from 0.4.24 on
/// 2026-09-10 and trimmed to the fields read here:
///
///     {"models":[
///       {"type":"llm","publisher":"unsloth","key":"qwen3.8-27b","display_name":"Qwen3.8 27B UD",
///        "architecture":"qwen35","quantization":{"name":"Q8_K_XL","bits_per_weight":8},
///        "size_bytes":31457991680,"params_string":"27B",
///        "loaded_instances":[{"id":"qwen3.8-27b","config":{"context_length":262144,
///          "eval_batch_size":2048,"physical_batch_size":1024,"parallel":1,"flash_attention":true}}],
///        "max_context_length":262144,"format":"gguf"},
///       {"type":"llm","key":"qwen/qwen3.6-35b-a3b","quantization":{"name":"8bit","bits_per_weight":8},
///        "size_bytes":37580963840,"loaded_instances":[],"max_context_length":262144,"format":"mlx"},
///       {"type":"embedding","key":"text-embedding-nomic-embed-text-v1.5","loaded_instances":[]}]}
///
/// One cell per *loaded instance*, named by the instance id. That id is what a
/// client passes as `model`, the tag LM Studio's server log writes on every
/// request, and the handle the processing-state poll reports on — so a model
/// loaded twice is two instances and two cells, and everything measured later
/// joins up by that one name. The model key is kept beside it only for the
/// brand mark, because an instance can be given any identifier at load time.
///
/// `size_bytes` is the weights' size on disk, not a memory reading: LM Studio
/// does not report residency, and the cell says "Model size" rather than
/// pretending otherwise. Embedding models are left out — they never generate,
/// so there is no speed, context or queue to show for one.
enum LMStudioUsage {
    private struct Response: Decodable {
        let models: [Model]
    }

    private struct Model: Decodable {
        struct Quantization: Decodable {
            let name: String?
        }
        struct Instance: Decodable {
            struct Config: Decodable {
                let context_length: Int?
            }
            let id: String
            let config: Config?
        }
        let type: String?
        let key: String
        let size_bytes: Int64?
        let quantization: Quantization?
        let max_context_length: Int?
        let loaded_instances: [Instance]?
    }

    static func parse(_ data: Data) throws -> LocalRuntimeReading {
        // A wrong port answers 200 with `{"error": …}` (LM Studio itself does,
        // for an unknown path), so the envelope has to be the listing's own.
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw LMStudioError.invalidResponse
        }
        var seen = Set<String>()
        let models = try response.models.filter { $0.type == "llm" }.flatMap { model in
            try (model.loaded_instances ?? []).map { instance in
                let id = instance.id.trimmingCharacters(in: .whitespacesAndNewlines)
                let context = instance.config?.context_length ?? model.max_context_length
                guard !id.isEmpty, seen.insert(id).inserted,
                      model.size_bytes.map({ $0 >= 0 }) ?? true,
                      context.map({ $0 > 0 }) ?? true else {
                    throw LMStudioError.invalidResponse
                }
                let quantization = model.quantization?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                return LocalRuntimeReading.Model(
                    name: id, memoryBytes: model.size_bytes, contextLength: context,
                    quantizationLevel: quantization?.isEmpty == false ? quantization : nil,
                    memoryKind: .modelSize, modelKey: model.key
                )
            }
        }.sorted { $0.id < $1.id }
        return LocalRuntimeReading(models: models, measuresSpeed: true)
    }
}
