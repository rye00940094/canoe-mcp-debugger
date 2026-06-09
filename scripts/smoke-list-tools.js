import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const client = new Client({ name: 'canoe-mcp-smoke-client', version: '0.1.0' });
const transport = new StdioClientTransport({
  command: 'node',
  args: ['src/server.js'],
  cwd: process.cwd(),
  stderr: 'pipe'
});

try {
  await client.connect(transport);
  const tools = await client.listTools();
  console.log(JSON.stringify({
    ok: true,
    count: tools.tools.length,
    tools: tools.tools.map((tool) => tool.name)
  }, null, 2));
} finally {
  await client.close();
}
