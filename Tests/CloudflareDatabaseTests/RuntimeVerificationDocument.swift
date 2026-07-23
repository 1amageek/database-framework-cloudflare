import Core
import DatabaseValue

@Persistable
struct RuntimeVerificationDocument {
    #Directory<RuntimeVerificationDocument>(
        "verification",
        "cloudflare-runtime"
    )

    var id: String = ""
    var title: String = ""
}
