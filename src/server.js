#!/usr/bin/env node
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import * as z from 'zod/v4';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const bridgeScript = resolve(__dirname, '..', 'scripts', 'canoe-bridge.ps1');
const sessionBridgeScript = resolve(__dirname, '..', 'scripts', 'canoe-session-bridge.ps1');

function psCommand() {
  return process.env.CANOE_MCP_POWERSHELL || 'powershell.exe';
}

let sessionBridge;

function startSessionBridge() {
  if (sessionBridge?.child && !sessionBridge.child.killed) return sessionBridge;

  const child = spawn(psCommand(), [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    sessionBridgeScript
  ], {
    windowsHide: true,
    stdio: ['pipe', 'pipe', 'pipe']
  });

  const lines = [];
  const waiters = [];
  const rl = createInterface({ input: child.stdout });
  let stderr = '';
  rl.on('line', (line) => {
    const waiter = waiters.shift();
    if (waiter) waiter(line);
    else lines.push(line);
  });
  child.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8'); });
  child.on('close', () => {
    while (waiters.length) waiters.shift()(null);
  });

  sessionBridge = { child, lines, waiters, stderr: () => stderr.trim() };
  return sessionBridge;
}

function runSessionBridge(action, args = {}, timeoutMs = 120_000) {
  return new Promise((resolvePromise) => {
    const bridge = startSessionBridge();
    const payload = JSON.stringify({ action, ...args });
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      resolvePromise({ ok: false, action, error: `Timeout after ${timeoutMs} ms`, stderr: bridge.stderr() || undefined });
    }, timeoutMs);

    const consume = (line) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (line === null) {
        resolvePromise({ ok: false, action, error: 'Session bridge exited', stderr: bridge.stderr() || undefined });
        return;
      }
      try {
        const parsed = JSON.parse(line.trim());
        resolvePromise({ action, ...parsed, stderr: bridge.stderr() || undefined, session: true });
      } catch (error) {
        resolvePromise({ ok: false, action, error: `Session bridge returned non-JSON line: ${error.message}`, stdout: line, stderr: bridge.stderr() || undefined, session: true });
      }
    };

    if (bridge.lines.length) consume(bridge.lines.shift());
    else bridge.waiters.push(consume);
    bridge.child.stdin.write(payload + '\n');
  });
}

function runBridge(action, args = {}, timeoutMs = 120_000) {
  if (process.env.CANOE_MCP_LEGACY_BRIDGE !== '1') {
    return runSessionBridge(action, args, timeoutMs);
  }
  return new Promise((resolvePromise) => {
    const payload = JSON.stringify({ action, ...args });
    const child = spawn(psCommand(), [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      bridgeScript,
      '-RequestJson',
      payload
    ], {
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe']
    });

    let stdout = '';
    let stderr = '';
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill('SIGKILL');
      resolvePromise({ ok: false, action, error: `Timeout after ${timeoutMs} ms`, stdout, stderr });
    }, timeoutMs);

    child.stdout.on('data', (chunk) => { stdout += chunk.toString('utf8'); });
    child.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8'); });
    child.on('close', (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      const trimmed = stdout.trim();
      if (trimmed) {
        try {
          const parsed = JSON.parse(trimmed);
          resolvePromise({ action, ...parsed, stderr: stderr.trim() || undefined, exitCode: code });
          return;
        } catch (error) {
          resolvePromise({ ok: false, action, error: `Bridge returned non-JSON stdout: ${error.message}`, stdout: trimmed, stderr: stderr.trim(), exitCode: code });
          return;
        }
      }
      resolvePromise({ ok: code === 0, action, error: code === 0 ? undefined : `Bridge exited with ${code}`, stderr: stderr.trim() || undefined, exitCode: code });
    });
  });
}

function textResult(result) {
  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
    isError: result.ok === false
  };
}

const server = new McpServer({
  name: 'canoe-mcp-debugger',
  version: '0.1.0'
});

server.registerTool('canoe_status', {
  description: 'Return CANoe COM attachment/configuration/measurement status and process information.',
  inputSchema: {}
}, async () => textResult(await runBridge('status', {}, 30_000)));

server.registerTool('canoe_open_configuration', {
  description: 'Open a CANoe .cfg/.canoe configuration via COM. Keeps CANoe available for following interactive calls.',
  inputSchema: {
    cfgPath: z.string().describe('Absolute CANoe configuration path, for example D:\\project\\BBS.cfg'),
    visible: z.boolean().default(true).describe('Make CANoe visible after opening'),
    autoSave: z.boolean().default(false).describe('Pass autoSave flag to CANoe Open'),
    promptUser: z.boolean().default(false).describe('Pass promptUser flag to CANoe Open')
  }
}, async (args) => textResult(await runBridge('open_configuration', args, 180_000)));

server.registerTool('canoe_compile_capl', {
  description: 'Compile CAPL in the currently open CANoe configuration.',
  inputSchema: {}
}, async () => textResult(await runBridge('compile_capl', {}, 180_000)));

server.registerTool('canoe_start_measurement', {
  description: 'Start CANoe measurement and report running state plus Write Window tail.',
  inputSchema: {
    timeoutMs: z.number().int().positive().default(30000).describe('How long to wait for measurement running state')
  }
}, async (args) => textResult(await runBridge('start_measurement', args, 90_000)));

server.registerTool('canoe_stop_measurement', {
  description: 'Stop CANoe measurement.',
  inputSchema: {
    timeoutMs: z.number().int().positive().default(30000).describe('How long to wait for measurement stopped state')
  }
}, async (args) => textResult(await runBridge('stop_measurement', args, 90_000)));

server.registerTool('canoe_read_write_window', {
  description: 'Read CANoe Write Window text, optionally returning only the tail lines.',
  inputSchema: {
    tailLines: z.number().int().positive().default(120).describe('Number of trailing lines to return')
  }
}, async (args) => textResult(await runBridge('read_write_window', args, 30_000)));

server.registerTool('canoe_get_system_variable', {
  description: 'Read a CANoe system variable value by namespace and variable name.',
  inputSchema: {
    namespace: z.string().describe('System variable namespace'),
    variable: z.string().describe('System variable name')
  }
}, async (args) => textResult(await runBridge('get_system_variable', args, 30_000)));

server.registerTool('canoe_set_system_variable', {
  description: 'Set a CANoe system variable value by namespace and variable name.',
  inputSchema: {
    namespace: z.string().describe('System variable namespace'),
    variable: z.string().describe('System variable name'),
    value: z.union([z.string(), z.number(), z.boolean()]).describe('New value')
  }
}, async (args) => textResult(await runBridge('set_system_variable', args, 30_000)));

server.registerTool('canoe_get_signal', {
  description: 'Read a CANoe bus signal value.',
  inputSchema: {
    bus: z.string().default('CAN').describe('Bus name, for example CAN/LIN/FlexRay'),
    channel: z.number().int().positive().default(1).describe('Channel number'),
    message: z.string().describe('Message/frame name'),
    signal: z.string().describe('Signal name')
  }
}, async (args) => textResult(await runBridge('get_signal', args, 30_000)));

server.registerTool('canoe_call_capl_function', {
  description: 'Call a CAPL function that is exposed through CANoe COM. CAPL function handles should normally be prepared during Measurement.OnInit.',
  inputSchema: {
    functionName: z.string().describe('CAPL function name'),
    args: z.array(z.union([z.string(), z.number(), z.boolean()])).default([]).describe('CAPL function arguments')
  }
}, async (args) => textResult(await runBridge('call_capl_function', args, 60_000)));

server.registerTool('canoe_list_test_modules', {
  description: 'Enumerate CANoe test environments and test modules.',
  inputSchema: {}
}, async () => textResult(await runBridge('list_test_modules', {}, 60_000)));

server.registerTool('canoe_set_test_module_enabled', {
  description: 'Enable or disable a test module while measurement is stopped.',
  inputSchema: {
    environment: z.string().optional().describe('Test environment name. Optional if module name is unique.'),
    module: z.string().optional().describe('Test module name. Optional when using moduleIndex.'),
    environmentIndex: z.number().int().positive().optional().describe('1-based test environment index'),
    moduleIndex: z.number().int().positive().optional().describe('1-based test module index within selected environment'),
    enabled: z.boolean().default(true).describe('Target Enabled state')
  }
}, async (args) => textResult(await runBridge('set_test_module_enabled', args, 60_000)));

server.registerTool('canoe_start_test_module', {
  description: 'Start a test module by environment/module name or index.',
  inputSchema: {
    environment: z.string().optional().describe('Test environment name. Optional if module name is unique.'),
    module: z.string().optional().describe('Test module name. Optional when using moduleIndex.'),
    environmentIndex: z.number().int().positive().optional().describe('1-based test environment index'),
    moduleIndex: z.number().int().positive().optional().describe('1-based test module index within selected environment'),
    timeoutMs: z.number().int().positive().default(30000).describe('How long to wait for TestModule.OnStart')
  }
}, async (args) => textResult(await runBridge('start_test_module', args, 60_000)));

server.registerTool('canoe_wait_measurement', {
  description: 'Wait for a measurement state transition using CANoe COM event semantics.',
  inputSchema: {
    state: z.enum(['started', 'stopped']).default('started').describe('Target measurement state'),
    timeoutMs: z.number().int().positive().default(30000).describe('How long to wait for the event')
  }
}, async (args) => textResult(await runBridge('wait_measurement', args, 90_000)));

server.registerTool('canoe_wait_test_module', {
  description: 'Wait for a test module to stop and return stop reason plus verdict when available.',
  inputSchema: {
    environment: z.string().optional().describe('Test environment name. Optional if module name is unique.'),
    module: z.string().optional().describe('Test module name. Optional when using moduleIndex.'),
    environmentIndex: z.number().int().positive().optional().describe('1-based test environment index'),
    moduleIndex: z.number().int().positive().optional().describe('1-based test module index within selected environment'),
    timeoutMs: z.number().int().positive().default(120000).describe('How long to wait for TestModule.OnStop')
  }
}, async (args) => textResult(await runBridge('wait_test_module', args, 150_000)));

server.registerTool('canoe_execute_test_environment', {
  description: 'Start all test modules in a test environment consecutively via TestEnvironment.ExecuteAll(). Requires measurement running.',
  inputSchema: {
    environment: z.string().optional().describe('Test environment name. Optional when using environmentIndex.'),
    environmentIndex: z.number().int().positive().optional().describe('1-based test environment index')
  }
}, async (args) => textResult(await runBridge('execute_test_environment', args, 90_000)));

server.registerTool('canoe_snapshot', {
  description: 'Collect a compact interactive debug snapshot: status, Write Window tail, and test module list.',
  inputSchema: {
    tailLines: z.number().int().positive().default(80)
  }
}, async (args) => textResult(await runBridge('snapshot', args, 60_000)));

const transport = new StdioServerTransport();
await server.connect(transport);
