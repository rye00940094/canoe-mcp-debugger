import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const client = new Client({ name: 'canoe-mcp-session-smoke', version: '0.1.0' });
const transport = new StdioClientTransport({ command: 'node', args: ['D:/BYD_AGC/canoe-mcp-debugger/src/server.js'] });
function text(response) { return JSON.parse(response.content.find((item) => item.type === 'text').text); }
await client.connect(transport);
const open = text(await client.callTool({ name: 'canoe_open_configuration', arguments: { cfgPath: 'D:/BYD_AGC/BYD_AGC_CANoe_XML_hil-power-relay-backends/BYD_AGC_SV.cfg', autoSave: false, promptUser: false } }));
const status = text(await client.callTool({ name: 'canoe_status', arguments: {} }));
const modules = text(await client.callTool({ name: 'canoe_list_test_modules', arguments: {} }));
console.log(JSON.stringify({ ok: open.ok && status.ok && status.attached && modules.ok, openOk: open.ok, statusAttached: status.attached, moduleCount: Array.isArray(modules.testEnvironments?.modules) ? modules.testEnvironments.modules.length : modules.testEnvironments?.modules?.length ?? null }, null, 2));
await client.close();
