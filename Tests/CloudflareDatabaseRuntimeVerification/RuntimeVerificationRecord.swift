import Core
import DatabaseValue

@Persistable
struct RuntimeVerificationRecord {
    #Directory<RuntimeVerificationRecord>(
        "verification",
        "cloudflare-runtime"
    )

    var id: String = ""
    var title: String = ""
}
