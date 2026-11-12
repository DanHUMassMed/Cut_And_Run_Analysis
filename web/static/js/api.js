export async function apiFetch(url, options = {}) {
  const response = await fetch(url, options);
  const contentType = response.headers.get('content-type') || '';
  const isJson = contentType.includes('application/json');
  const payload = isJson ? await response.json().catch(() => null) : null;

  if (!response.ok) {
    let message = `HTTP ${response.status}`;
    if (payload?.detail) {
      if (Array.isArray(payload.detail)) {
        message = payload.detail
          .map((err) => `${(err.loc || []).slice(-1)[0] || 'field'}: ${err.msg}`)
          .join('; ');
      } else {
        message = String(payload.detail);
      }
    }
    throw new Error(message);
  }
  return payload;
}

