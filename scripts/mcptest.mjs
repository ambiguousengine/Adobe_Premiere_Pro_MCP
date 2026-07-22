// Minimal stdio MCP client: calls tools on the rebuilt server without needing a Claude restart.
import { spawn } from 'node:child_process';

const calls = JSON.parse(process.argv[2]);
const srv = spawn('node', ['F:\\AMBIGUITY\\TOOLS\\premiere-mcp\\dist\\index.js'], {
  env: { ...process.env, PREMIERE_TEMP_DIR: 'C:\\Users\\simon\\AppData\\Local\\Temp\\premiere-mcp-bridge' },
  stdio: ['pipe', 'pipe', 'pipe'],
});

let buf = '';
const pending = new Map();
srv.stdout.on('data', (d) => {
  buf += d.toString();
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    try {
      const msg = JSON.parse(line);
      if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
    } catch {}
  }
});

let id = 0;
const send = (method, params) => new Promise((res) => {
  const myId = ++id;
  pending.set(myId, res);
  srv.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: myId, method, params }) + '\n');
});

await send('initialize', {
  protocolVersion: '2024-11-05',
  capabilities: {},
  clientInfo: { name: 'ambiguity-test', version: '1.0' },
});
srv.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');

for (const c of calls) {
  const r = await send('tools/call', { name: c.name, arguments: c.args || {} });
  const text = r.result?.content?.[0]?.text ?? JSON.stringify(r.error ?? r);
  console.log(`\n=== ${c.name} ===\n${text}`);
}
srv.kill();
process.exit(0);
