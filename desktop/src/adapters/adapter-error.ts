export type AdapterErrorCode =
  | "NOT_IMPLEMENTED"
  | "BACKEND_UNAVAILABLE"
  | "INVALID_RESPONSE";

export class AdapterError extends Error {
  constructor(
    public readonly code: AdapterErrorCode,
    message: string,
  ) {
    super(message);
    this.name = "AdapterError";
  }
}

export function isAdapterError(error: unknown): error is AdapterError {
  return error instanceof AdapterError;
}
