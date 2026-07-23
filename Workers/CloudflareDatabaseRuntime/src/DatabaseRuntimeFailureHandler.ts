/**
 * Terminates the owning Durable Object after the database runtime stops obeying
 * the request/completion protocol.
 */
export type DatabaseRuntimeFailureHandler = (reason: string) => void;
