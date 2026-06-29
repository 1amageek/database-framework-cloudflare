const bearerPrefix = "Bearer ";

export class RequestAuthorizer {
  private readonly secret: string | null;

  constructor(secret: unknown) {
    this.secret = normalizedSecret(secret);
  }

  async authorize(request: Request): Promise<AuthorizationResult> {
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
  readonly allowed: boolean;
  readonly response: Response | null;

  static authorized(): AuthorizationResult {
    return new AuthorizationResult(true, null);
  }

  static unauthorized(): AuthorizationResult {
    return new AuthorizationResult(false, new Response("Unauthorized", {
      status: 401,
      headers: {
        "www-authenticate": "Bearer",
      },
    }));
  }

  static misconfigured(): AuthorizationResult {
    return new AuthorizationResult(false, new Response("Database access token is not configured", {
      status: 503,
    }));
  }

  private constructor(allowed: boolean, response: Response | null) {
    this.allowed = allowed;
    this.response = response;
  }
}

function normalizedSecret(secret: unknown): string | null {
  if (typeof secret !== "string") {
    return null;
  }
  const trimmed = secret.trim();
  return trimmed.length === 0 ? null : trimmed;
}

async function constantTimeStringEqual(lhs: string, rhs: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [lhsHash, rhsHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(lhs)),
    crypto.subtle.digest("SHA-256", encoder.encode(rhs)),
  ]);
  return constantTimeBytesEqual(new Uint8Array(lhsHash), new Uint8Array(rhsHash));
}

function constantTimeBytesEqual(lhs: Uint8Array, rhs: Uint8Array): boolean {
  let difference = lhs.length ^ rhs.length;
  const count = Math.max(lhs.length, rhs.length);
  for (let index = 0; index < count; index += 1) {
    difference |= (lhs[index] ?? 0) ^ (rhs[index] ?? 0);
  }
  return difference === 0;
}
