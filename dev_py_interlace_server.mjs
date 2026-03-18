import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

function readJson(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', chunk => {
      data += chunk;
      if (data.length > 50 * 1024 * 1024) {
        reject(new Error('payload too large'));
        req.destroy();
      }
    });
    req.on('end', () => {
      try {
        resolve(JSON.parse(data || '{}'));
      } catch (e) {
        reject(e);
      }
    });
    req.on('error', reject);
  });
}

function b64ToBuffer(b64OrDataUri) {
  const s = String(b64OrDataUri || '');
  const idx = s.indexOf('base64,');
  const b64 = idx >= 0 ? s.slice(idx + 'base64,'.length) : s;
  return Buffer.from(b64, 'base64');
}

async function ensureDir(p) {
  await fs.mkdir(p, { recursive: true });
}

function runPythonInterleave({
  projectRoot,
  inputDir,
  outputPath,
  valX,
  valTan,
  offset,
  size,
}) {
  return new Promise((resolve, reject) => {
    const py = path.join(projectRoot, '.venv', 'bin', 'python');
    const script = path.join(projectRoot, 'MyApp', 'interleaveV2.py');
    const args = [
      script,
      '--input_dir',
      inputDir,
      '--output',
      outputPath,
      '--mode',
      'formula',
      '--val_x',
      String(valX),
      '--val_tan',
      String(valTan),
      '--offset',
      String(offset),
    ];
    if (size) {
      args.push('--size', String(size));
    }

    const child = spawn(py, args, { cwd: projectRoot });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', d => (stdout += d.toString()));
    child.stderr.on('data', d => (stderr += d.toString()));
    child.on('error', reject);
    child.on('close', code => {
      if (code === 0) resolve({ stdout, stderr });
      else reject(new Error(`python exit ${code}\n${stderr || stdout}`));
    });
  });
}

const server = createServer(async (req, res) => {
  try {
    if (req.method === 'GET' && req.url === '/health') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
      return;
    }

    if (req.method !== 'POST' || req.url !== '/interlace') {
      res.writeHead(404, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: false, error: 'not found' }));
      return;
    }

    const body = await readJson(req);
    const images = Array.isArray(body.images) ? body.images : [];
    if (images.length < 2) {
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: false, error: 'images length must be >= 2' }));
      return;
    }

    const valX = Number(body.val_x ?? 10);
    const valTan = Number(body.val_tan ?? 0.277777);
    const offset = Number(body.offset ?? 0);
    const size = typeof body.size === 'string' && body.size.trim() ? body.size.trim() : '';

    const __filename = fileURLToPath(import.meta.url);
    const __dirname = path.dirname(__filename);
    const projectRoot = path.resolve(__dirname, '..'); // .../ThreeDApp2

    const ts = Date.now().toString();
    const baseDir = path.join(projectRoot, 'MyApp', '_py_interlace_tmp', ts);
    const inputDir = path.join(baseDir, 'in');
    const outputPath = path.join(baseDir, 'out.png');
    await ensureDir(inputDir);

    await Promise.all(
      images.map((b64, i) =>
        fs.writeFile(path.join(inputDir, `${i + 1}.png`), b64ToBuffer(b64)),
      ),
    );

    await runPythonInterleave({
      projectRoot,
      inputDir,
      outputPath,
      valX,
      valTan,
      offset,
      size,
    });

    const outBuf = await fs.readFile(outputPath);
    const outB64 = outBuf.toString('base64');

    // best-effort cleanup
    fs.rm(baseDir, { recursive: true, force: true }).catch(() => {});

    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, image_base64: outB64 }));
  } catch (e) {
    res.writeHead(500, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: false, error: e instanceof Error ? e.message : String(e) }));
  }
});

const port = Number(process.env.PY_INTERLACE_PORT || 8787);
const host = process.env.PY_INTERLACE_HOST || '0.0.0.0';
server.on('error', err => {
  if (err && err.code === 'EADDRINUSE') {
    // eslint-disable-next-line no-console
    console.error(
      `端口被占用：${host}:${port}\n` +
        `解决办法：\n` +
        `- 结束占用端口的进程，或\n` +
        `- 换端口启动：PY_INTERLACE_PORT=8788 npm run py:interlace\n` +
        `同时把 App.tsx 里的 baseUrl 改成 http://localhost:8788`,
    );
    process.exit(1);
  } else {
    // eslint-disable-next-line no-console
    console.error(err);
    process.exit(1);
  }
});

server.listen(port, host, () => {
  // eslint-disable-next-line no-console
  console.log(`py interlace server listening on http://${host}:${port}`);
  const nets = os.networkInterfaces();
  const ipv4s = Object.values(nets)
    .flat()
    .filter(Boolean)
    .filter(n => n.family === 'IPv4' && !n.internal)
    .map(n => n.address);
  const uniq = [...new Set(ipv4s)];
  if (uniq.length) {
    // eslint-disable-next-line no-console
    console.log('局域网可访问地址（真机用这个）：');
    for (const ip of uniq) {
      // eslint-disable-next-line no-console
      console.log(`- http://${ip}:${port}`);
    }
  }
});

