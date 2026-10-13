import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';

const executable = process.argv[2];
if (!executable) throw new Error('Usage: node script/check_mcp.mjs /path/to/RepriseMCP');
const root = await mkdtemp(join(tmpdir(), 'reprise-protocol-test-'));
const child = spawn(resolve(executable), ['--vault', root], { stdio: ['pipe', 'pipe', 'pipe'] });
const pending = new Map();
let serial = 0;
let stderr = '';
const timeout = setTimeout(() => { child.kill('SIGKILL'); process.exitCode = 1; }, 15000);
child.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-4096); });
const exit = new Promise((resolve, reject) => {
  child.on('error', reject);
  child.on('exit', (code, signal) => {
    for (const request of pending.values()) request.reject(new Error(`MCP exited: ${code}/${signal} ${stderr}`));
    resolve({ code, signal });
  });
});
createInterface({ input: child.stdout }).on('line', line => {
  try {
    const response = JSON.parse(line);
    if (!pending.has(response.id)) return;
    const request = pending.get(response.id);
    pending.delete(response.id);
    if (response.error) request.reject(new Error(JSON.stringify(response.error)));
    else request.resolve(response.result);
  } catch (error) {
    for (const request of pending.values()) request.reject(error);
    child.kill();
  }
});
const call = (method, params) => new Promise((resolve, reject) => {
  const id = ++serial;
  pending.set(id, { resolve, reject });
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
});
try {
  const initialized = await call('initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'Reprise fixture', version: '1' } });
  assert.equal(initialized.serverInfo.name, 'Reprise');
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  const tools = await call('tools/list', {});
  assert.equal(tools.tools.length, 5);
  assert(tools.tools.every(tool => tool.annotations.readOnlyHint));
  const denied = await call('tools/call', { name: 'reprise_library_status', arguments: {} });
  assert.equal(denied.isError, true);
  assert.match(denied.content[0].text, /disabled/);
  child.stdin.end();
  const result = await exit;
  assert.equal(result.code, 0);
  console.log('MCP stdio initialize, tool discovery, default-deny and clean EOF passed.');
} finally {
  clearTimeout(timeout);
  if (child.exitCode === null) { child.kill('SIGKILL'); await exit; }
  await rm(root, { recursive: true, force: true });
}
