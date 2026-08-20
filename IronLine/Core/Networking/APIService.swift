import Foundation
import Supabase

/// Thin wrapper for invoking backend Edge Functions.
/// Direct table reads/writes go through SupabaseConfig.client instead — see docs/api-contracts.md.
enum APIService {
    static func invoke<Response: Decodable>(
        _ function: String,
        body: some Encodable
    ) async throws -> Response {
        try await SupabaseConfig.client.functions.invoke(
            function,
            options: .init(body: body)
        )
    }

    static func invokeGET<Response: Decodable>(
        _ function: String,
        query: [URLQueryItem]
    ) async throws -> Response {
        try await SupabaseConfig.client.functions.invoke(
            function,
            options: .init(method: .get, query: query)
        )
    }
}
