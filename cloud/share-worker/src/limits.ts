// All limits are first guesses (see README). Kept apart from index.ts because a Worker module's
// named exports must be handlers.
export const MAX_FILE_BYTES = 4 * 1024 * 1024;
export const MAX_INSTALL_BYTES = 300 * 1024 * 1024;
export const RATE_LIMIT_MAX = 10; // installations per address per window
export const RATE_LIMIT_WINDOW_SECONDS = 3600;
