function errorHandler(err, req, res, next) {
  const statusCode = err.statusCode || 500;
  const errorCode = err.errorCode || 'INTERNAL_ERROR';
  const timestamp = new Date().toISOString();

  let message = err.message;
  if (!message) {
    if (typeof err === 'string') message = err;
    else if (err && err.toString) message = err.toString();
    else message = 'Unknown error';
  }

  let details = err.details || null;
  if (!details && err.stack && statusCode >= 500) {
    details = err.stack;
  }

  if (statusCode >= 500) {
    console.error(`[${timestamp}] ${req.method} ${req.originalUrl} -> ${statusCode}:`, message);
    if (err.stack) console.error(err.stack);
  }

  res.status(statusCode).json({
    error: {
      code: errorCode,
      message: message,
      details: details,
      path: req.originalUrl,
      method: req.method,
      timestamp
    }
  });
}

function notFoundHandler(req, res) {
  res.status(404).json({
    error: {
      code: 'NOT_FOUND',
      message: `Resource not found: ${req.method} ${req.originalUrl}`,
      path: req.originalUrl,
      method: req.method,
      timestamp: new Date().toISOString()
    }
  });
}

class AppError extends Error {
  constructor(message, statusCode = 400, errorCode = 'BAD_REQUEST', details = null) {
    super(message);
    this.name = 'AppError';
    this.statusCode = statusCode;
    this.errorCode = errorCode;
    this.details = details;
  }
}

module.exports = { errorHandler, notFoundHandler, AppError };
