const bearerPrefix = "Bearer ";

export class RequestAuthorizer {
  constructor(secret) {
    this.secret = normalizedSecret(secret);
  }

  async authorize(request) {
    if (this.secret === null) {
      return AuthorizationResult.misconfigured();
    }

    const authorization = request.headers.get("authorization");
    if (authorization === null || !authorization.startsWith(bearerPrefix)) {
      return AuthorizationResult.unauthorized();
    }

    const token = authorization.slice(bearerPrefix.length);
    if (token.length === 0) {
      return AuthorizationResult.unauthorized();
    }

    const authorized = await constantTimeStringEqual(token, this.secret);
    return authorized ? AuthorizationResult.authorized() : AuthorizationResult.unauthorized();
  }
}

export class AuthorizationResult {
  static authorized() {
    return new AuthorizationResult(true, null);
  }

  static unauthorized() {
    return new AuthorizationResult(false, new Response("Unauthorized", {
      status: 401,
      headers: {
        "www-authenticate": "Bearer",
      },
    }));
  }

  static misconfigured() {
    return new AuthorizationResult(false, new Response("Database access token is not configured", {
      status: 503,
    }));
  }

  constructor(allowed, response) {
    this.allowed = allowed;
    this.response = response;
  }
}

function normalizedSecret(secret) {
  if (typeof secret !== "string") {
    return null;
  }
  const trimmed = secret.trim();
  return trimmed.length === 0 ? null : trimmed;
}

async function constantTimeStringEqual(lhs, rhs) {
  const encoder = new TextEncoder();
  const [lhsHash, rhsHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(lhs)),
    crypto.subtle.digest("SHA-256", encoder.encode(rhs)),
  ]);
  return constantTimeBytesEqual(new Uint8Array(lhsHash), new Uint8Array(rhsHash));
}

function constantTimeBytesEqual(lhs, rhs) {
  let difference = lhs.length ^ rhs.length;
  const count = Math.max(lhs.length, rhs.length);
  for (let index = 0; index < count; index += 1) {
    difference |= (lhs[index] ?? 0) ^ (rhs[index] ?? 0);
  }
  return difference === 0;
}
