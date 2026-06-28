import CloudflareDatabase
import DatabaseEngine

struct FailingStorageHost: DatabaseStorageHost {
    func dispatch(
        _ request: DatabaseStorageHostRequest
    ) throws(DatabaseRuntimeError) -> DatabaseStorageHostResponse {
        .failure("host unavailable")
    }
}
