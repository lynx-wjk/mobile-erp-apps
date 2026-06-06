module.exports = async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Cache-Control', 'no-store');

  if (req.method === 'OPTIONS') {
    return res.status(204).end();
  }

  if (req.method === 'GET') {
    return res.status(200).json({
      ok: true,
      message: 'Drive upload proxy is alive',
    });
  }

  if (req.method !== 'POST') {
    return res.status(405).json({
      ok: false,
      message: 'Method not allowed',
    });
  }

  const uploadUrl = (process.env.GOOGLE_DRIVE_UPLOAD_URL || '').trim();
  const token = (process.env.GOOGLE_DRIVE_UPLOAD_TOKEN || '').trim();

  if (!uploadUrl) {
    return res.status(500).json({
      ok: false,
      message: 'GOOGLE_DRIVE_UPLOAD_URL belum diset di Vercel Environment Variables',
    });
  }

  if (!token) {
    return res.status(500).json({
      ok: false,
      message: 'GOOGLE_DRIVE_UPLOAD_TOKEN belum diset di Vercel Environment Variables',
    });
  }

  let body = req.body;

  try {
    if (typeof body === 'string') {
      body = body.trim() ? JSON.parse(body) : {};
    }

    if (Buffer.isBuffer(body)) {
      body = JSON.parse(body.toString('utf8'));
    }

    if (!body || typeof body !== 'object') {
      body = {};
    }
  } catch (error) {
    return res.status(400).json({
      ok: false,
      message: 'Body JSON tidak valid',
      detail: String(error && error.message ? error.message : error),
    });
  }

  const fileName = String(body.fileName || '').trim();
  const mimeType = String(body.mimeType || 'image/jpeg').trim();
  const base64Data = String(body.base64Data || '').trim();

  if (!fileName) {
    return res.status(400).json({
      ok: false,
      message: 'fileName kosong',
    });
  }

  if (!base64Data) {
    return res.status(400).json({
      ok: false,
      message: 'base64Data kosong',
    });
  }

  try {
    const upstreamPayload = {
      token,
      fileName,
      mimeType,
      base64Data,
    };

    const upstreamResponse = await fetch(uploadUrl, {
      method: 'POST',
      headers: {
        // text/plain sengaja dipakai supaya Apps Script tetap bisa baca e.postData.contents
        // dan tidak perlu main-main dengan preflight browser. Ini request server-to-server.
        'Content-Type': 'text/plain;charset=utf-8',
        'Accept': 'application/json,text/plain,*/*',
      },
      body: JSON.stringify(upstreamPayload),
      redirect: 'follow',
    });

    const text = await upstreamResponse.text();

    let decoded;
    try {
      decoded = JSON.parse(text);
    } catch (_) {
      decoded = null;
    }

    if (!upstreamResponse.ok) {
      return res.status(upstreamResponse.status).json({
        ok: false,
        message: 'Apps Script upload gagal',
        httpStatus: upstreamResponse.status,
        response: text.slice(0, 1000),
      });
    }

    if (!decoded || typeof decoded !== 'object') {
      return res.status(502).json({
        ok: false,
        message: 'Response Apps Script bukan JSON valid',
        response: text.slice(0, 1000),
      });
    }

    return res.status(200).json(decoded);
  } catch (error) {
    return res.status(500).json({
      ok: false,
      message: 'Proxy upload gagal',
      detail: String(error && error.message ? error.message : error),
    });
  }
};
