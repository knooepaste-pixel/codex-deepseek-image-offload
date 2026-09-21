const ORDER = {
  silent: 0,
  error: 1,
  warn: 2,
  info: 3,
  debug: 4,
};

export function createLogger(level = "info") {
  const threshold = ORDER[level] ?? ORDER.info;

  function write(name, message, detail) {
    if (ORDER[name] > threshold) {
      return;
    }
    const line = detail === undefined
      ? `[${new Date().toISOString()}] ${name.toUpperCase()} ${message}`
      : `[${new Date().toISOString()}] ${name.toUpperCase()} ${message} ${JSON.stringify(detail)}`;
    const target = name === "error" ? process.stderr : process.stdout;
    target.write(`${line}\n`);
  }

  return {
    error: (message, detail) => write("error", message, detail),
    warn: (message, detail) => write("warn", message, detail),
    info: (message, detail) => write("info", message, detail),
    debug: (message, detail) => write("debug", message, detail),
  };
}
