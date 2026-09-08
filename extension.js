'use strict';

const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, execFile } = require('child_process');

const IS_WINDOWS = process.platform === 'win32';
const IS_MAC = process.platform === 'darwin';
const IS_LINUX = process.platform === 'linux';
const IS_POSIX = IS_MAC || IS_LINUX;

const WINDOWS_ROOT = process.env.SystemRoot || 'C:\\Windows';

const POWERSHELL = path.join(
  WINDOWS_ROOT,
  'System32',
  'WindowsPowerShell',
  'v1.0',
  'powershell.exe'
);

const BASH = '/bin/bash';
const OSASCRIPT = '/usr/bin/osascript';

// Common Linux terminal emulators, tried in this order, each with its own
// argv syntax for "run this command, don't just open a shell". There is no
// Linux equivalent of AppleScript/Terminal.app - desktop environments vary,
// so this is a best-effort chain rather than a single known-correct path.
const LINUX_TERMINAL_CANDIDATES = [
  { bin: '/usr/bin/gnome-terminal', buildArgs: (cmd) => ['--', BASH, '-c', cmd] },
  { bin: '/usr/bin/konsole', buildArgs: (cmd) => ['-e', BASH, '-c', cmd] },
  { bin: '/usr/bin/xfce4-terminal', buildArgs: (cmd) => ['-x', BASH, '-c', cmd] },
  { bin: '/usr/bin/xterm', buildArgs: (cmd) => ['-e', BASH, '-c', cmd] }
];

// Windows OpenSSH lives under System32; macOS and Linux both ship an
// OpenSSH client at this same fixed path. Hardcoding it (rather than
// relying on PATH) is deliberate - it always finds the same client the
// rest of the system uses, regardless of the calling process's environment.
const SSH_EXE = IS_WINDOWS
  ? path.join(WINDOWS_ROOT, 'System32', 'OpenSSH', 'ssh.exe')
  : '/usr/bin/ssh';

const TERMINAL_WINDOW_LABEL = IS_WINDOWS ? 'PowerShell' : 'Terminal';

const HIDDEN_SETUP_TIMEOUT_MS = 120000;
const INTERACTIVE_SETUP_TIMEOUT_MS = 180000;
const SSH_TEST_TIMEOUT_MS = 10000;

let outputChannel;

function logOutput(message) {
  if (!outputChannel) {
    return;
  }

  const timestamp = new Date().toLocaleTimeString();

  outputChannel.appendLine(`[${timestamp}] ${message}`);
}

function logLines(prefix, text) {
  if (!text || !text.trim()) {
    return;
  }

  logOutput(`${prefix}:`);

  for (const line of text.trimEnd().split(/\r?\n/)) {
    logOutput(`  ${line}`);
  }
}

// Kills the whole process tree by PID. A plain child.kill() only signals the
// immediate process; ssh / ssh-keygen launched underneath it would be left
// running otherwise. On Windows this uses taskkill's tree-kill flag; on
// macOS the process is spawned detached (see runProcess), making it its own
// process group leader, so signaling the negative PID reaches the whole
// group instead of just that one process.
function killProcessTree(pid) {
  return new Promise((resolve) => {
    if (IS_WINDOWS) {
      execFile(
        'taskkill',
        ['/PID', String(pid), '/T', '/F'],
        { windowsHide: true },
        () => resolve()
      );
      return;
    }

    try {
      process.kill(-pid, 'SIGKILL');
    } catch (groupError) {
      try {
        process.kill(pid, 'SIGKILL');
      } catch (pidError) {
        // Process likely already exited.
      }
    }

    resolve();
  });
}

// Centralized subprocess runner. Every async operation in this extension goes
// through this function so that every process either resolves, or is killed
// on an explicit timeout - no promise is ever left hanging.
//
// Always runs hidden with piped output: a real, on-screen window (for the
// password-entry flow) is produced by having the hidden process itself launch
// a separate window via PowerShell's Start-Process -WindowStyle Normal (see
// runInteractiveSetup) rather than by trying to make this process's own
// window visible - relying on Windows' default console-allocation behavior
// for a directly spawned console app turned out not to reliably show a
// window from inside the real VS Code extension host process tree.
function runProcess(file, args, { timeoutMs, env } = {}) {
  const label = path.basename(file);

  logOutput(`Running ${label} (timeout ${timeoutMs}ms).`);

  return new Promise((resolve) => {
    let child;

    try {
      child = spawn(file, args, {
        windowsHide: true,
        // On POSIX, detach so the child becomes its own process group
        // leader - required for killProcessTree's negative-PID group kill
        // to reach any grandchildren (eg. ssh-keygen) on timeout.
        detached: !IS_WINDOWS,
        stdio: 'pipe',
        env: env || process.env
      });
    } catch (spawnError) {
      logOutput(`${label} failed to start: ${spawnError.message}`);

      resolve({
        code: null,
        stdout: '',
        stderr: '',
        error: spawnError,
        timedOut: false
      });

      return;
    }

    let stdout = '';
    let stderr = '';
    let settled = false;
    let timedOut = false;

    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString();
    });

    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
    });

    const timer = setTimeout(() => {
      if (settled) {
        return;
      }

      timedOut = true;

      logOutput(`${label} timed out after ${timeoutMs}ms. Terminating.`);

      if (typeof child.pid === 'number') {
        killProcessTree(child.pid);
      }
    }, timeoutMs);

    function finish(code, spawnError) {
      if (settled) {
        return;
      }

      settled = true;
      clearTimeout(timer);

      const finalError =
        spawnError ||
        (timedOut
          ? new Error(`${label} timed out after ${timeoutMs}ms.`)
          : code !== 0
            ? new Error(`${label} exited with code ${code}.`)
            : null);

      logOutput(
        `${label} => ${timedOut ? 'TIMEOUT' : finalError ? 'FAILED' : 'OK'} (exit code ${code})`
      );

      logLines('stdout', stdout);
      logLines('stderr', stderr);

      resolve({ code, stdout, stderr, error: finalError, timedOut });
    }

    child.once('error', (error) => {
      logOutput(`${label} process error: ${error.message}`);
      finish(null, error);
    });

    child.once('close', (code) => {
      finish(code, null);
    });
  });
}

function getSSHConfigPath() {
  return path.join(os.homedir(), '.ssh', 'config');
}

function isWildcardAlias(alias) {
  return !alias || alias.includes('*') || alias.includes('?');
}

function getSSHHosts() {
  const configPath = getSSHConfigPath();

  if (!fs.existsSync(configPath)) {
    return [];
  }

  const text = fs.readFileSync(configPath, 'utf8');
  const hosts = [];

  let currentAliases = [];
  let currentHostName = null;

  function flushBlock() {
    for (const alias of currentAliases) {
      if (isWildcardAlias(alias)) {
        continue;
      }

      if (!hosts.some((item) => item.host === alias)) {
        hosts.push({
          host: alias,
          hostname: currentHostName || alias
        });
      }
    }
  }

  for (const line of text.split(/\r?\n/)) {
    const hostMatch = line.match(/^\s*Host\s+(.+?)\s*$/i);

    if (hostMatch) {
      flushBlock();

      currentAliases = hostMatch[1].trim().split(/\s+/);
      currentHostName = null;

      continue;
    }

    const hostnameMatch = line.match(/^\s*HostName\s+(.+?)\s*$/i);

    if (hostnameMatch && currentAliases.length) {
      currentHostName = hostnameMatch[1].trim();
    }
  }

  flushBlock();

  return hosts.sort((a, b) => a.host.localeCompare(b.host));
}

async function pickHost() {
  const hosts = getSSHHosts();

  if (!hosts.length) {
    vscode.window.showErrorMessage(
      `No SSH hosts were found in ${getSSHConfigPath()}.`
    );

    return null;
  }

  return vscode.window.showQuickPick(
    hosts.map((item) => ({
      label: `$(server) ${item.host}`,
      description: item.hostname,
      host: item.host,
      hostname: item.hostname
    })),
    {
      title: 'SSH Key Manager',
      placeHolder: 'Select an SSH host',
      matchOnDescription: true
    }
  );
}

async function testPasswordless(host) {
  const result = await runProcess(
    SSH_EXE,
    [
      '-o', 'BatchMode=yes',
      '-o', 'ConnectTimeout=6',
      '-o', 'ConnectionAttempts=1',
      '-o', 'ServerAliveInterval=3',
      '-o', 'ServerAliveCountMax=1',
      host,
      'printf SSH_KEY_AUTH_SUCCESS'
    ],
    { timeoutMs: SSH_TEST_TIMEOUT_MS }
  );

  return {
    success: !result.error && result.stdout.includes('SSH_KEY_AUTH_SUCCESS'),
    result
  };
}

function bundledScriptPath(context) {
  const scriptName = IS_POSIX ? 'setup-ssh-key.sh' : 'setup-ssh-key.ps1';
  return context.asAbsolutePath(path.join('scripts', scriptName));
}

function formatFailure(result) {
  if (!result) {
    return 'Unknown error.';
  }

  if (result.timedOut) {
    return 'The operation timed out.';
  }

  const message = [result.stderr, result.stdout, result.error?.message]
    .filter(Boolean)
    .join('\n')
    .trim();

  return message || 'Unknown error.';
}

function runHiddenSetup(context, host) {
  const script = bundledScriptPath(context);

  if (IS_POSIX) {
    return runProcess(
      BASH,
      [script, '--host-alias', host, '--non-interactive'],
      { timeoutMs: HIDDEN_SETUP_TIMEOUT_MS }
    );
  }

  return runProcess(
    POWERSHELL,
    [
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', script,
      '-HostAlias', host,
      '-NonInteractiveMode'
    ],
    { timeoutMs: HIDDEN_SETUP_TIMEOUT_MS }
  );
}

// Safely embeds a value inside a single-quoted PowerShell string literal by
// doubling any embedded single quotes - the standard PowerShell escaping
// rule for this case.
function powershellSingleQuote(value) {
  return `'${String(value).replace(/'/g, "''")}'`;
}

// Safely embeds a value inside a single-quoted POSIX shell string by
// closing the quote, appending an escaped literal quote, and reopening it -
// the standard POSIX shell escaping rule for this case. Verified against
// real bash (including that shell metacharacters like $() and backticks
// stay inert inside the resulting single-quoted text).
function posixSingleQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

// Escapes a value for embedding inside an AppleScript "..." string literal -
// AppleScript string escaping only needs backslash and double-quote handled.
function appleScriptQuote(value) {
  return String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

function runInteractiveSetup(context, host, regenerate) {
  return IS_POSIX
    ? runInteractiveSetupPosix(context, host, regenerate)
    : runInteractiveSetupWindows(context, host, regenerate);
}

function runInteractiveSetupWindows(context, host, regenerate) {
  const script = bundledScriptPath(context);

  // Passing -HostAlias through Start-Process's -ArgumentList was tested and
  // found unreliable: an array-based ArgumentList mangles values containing
  // an embedded single quote, and the alternative of hand-building a quoted
  // command-line string reintroduces the exact fragile-quoting problem this
  // needs to avoid. An environment variable has no such parsing step at all,
  // so the host alias (arbitrary text from the user's SSH config) travels
  // through untouched no matter what characters it contains.
  //
  // The script path is still passed as a command-line argument, but as a
  // single pre-quoted string (not an array) - Windows paths can never
  // contain a literal double quote, so simple "..." wrapping is unambiguous
  // and was verified to survive spaces in the path, unlike the array form.
  const rawInnerArgs = `-NoProfile -ExecutionPolicy Bypass -File "${script}"`;

  // This outer PowerShell process runs hidden (see runProcess) and only
  // launches + waits for the real, visible window via Start-Process - which
  // reliably creates an on-screen window regardless of how the extension
  // host itself is attached to a console.
  const command =
    `$p = Start-Process -FilePath ${powershellSingleQuote(POWERSHELL)} ` +
    `-ArgumentList ${powershellSingleQuote(rawInnerArgs)} -WindowStyle Normal -PassThru -Wait; ` +
    `exit $p.ExitCode`;

  return runProcess(
    POWERSHELL,
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', command],
    {
      timeoutMs: INTERACTIVE_SETUP_TIMEOUT_MS,
      env: {
        ...process.env,
        SSHKEYMGR_HOST_ALIAS: host,
        SSHKEYMGR_REGENERATE: regenerate ? '1' : '0'
      }
    }
  );
}

// Finds the first available Linux terminal emulator from
// LINUX_TERMINAL_CANDIDATES. Returns null if none of them are installed -
// there is no single standard terminal on Linux the way there is on macOS.
function findLinuxTerminal() {
  for (const candidate of LINUX_TERMINAL_CANDIDATES) {
    if (fs.existsSync(candidate.bin)) {
      return candidate;
    }
  }

  return null;
}

// Builds the {file, args} needed to launch a real, visible terminal window
// running shellCommand. Returns null only on Linux, when no candidate
// terminal emulator could be found at all.
function buildTerminalLaunch(shellCommand) {
  if (IS_MAC) {
    const appleScript =
      'tell application "Terminal"\n' +
      'activate\n' +
      `do script "${appleScriptQuote(shellCommand)}"\n` +
      'end tell';

    return { file: OSASCRIPT, args: ['-e', appleScript] };
  }

  const terminal = findLinuxTerminal();

  return terminal ? { file: terminal.bin, args: terminal.buildArgs(shellCommand) } : null;
}

// Neither macOS nor Linux have an equivalent of PowerShell's Start-Process
// -WindowStyle Normal, so the visible password-entry window is a real
// terminal window/tab launched via a platform-specific mechanism
// (AppleScript + Terminal.app on macOS; a best-effort terminal-emulator
// chain on Linux, since there is no single standard there). That launch
// step returns as soon as the terminal has been told to run something - it
// does not wait for the command to finish - so completion is detected by
// having the launched shell write its own exit code to a sentinel file
// that this function polls for, with the same overall timeout as the
// Windows path. A PID file written by the same shell command lets a
// timeout actually kill the process group, mirroring killProcessTree's
// tree-kill on Windows.
function runInteractiveSetupPosix(context, host, regenerate) {
  const script = bundledScriptPath(context);
  const token = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const sentinelPath = path.join(os.tmpdir(), `sshkeymgr-status-${token}`);
  const pidPath = path.join(os.tmpdir(), `sshkeymgr-pid-${token}`);

  const scriptArgs = [script, '--host-alias', host];

  if (regenerate) {
    scriptArgs.push('--regenerate');
  }

  const shellCommand =
    `echo $$ > ${posixSingleQuote(pidPath)}; ` +
    `${posixSingleQuote(BASH)} ${scriptArgs.map(posixSingleQuote).join(' ')}; ` +
    `echo $? > ${posixSingleQuote(sentinelPath)}; ` +
    `exit`;

  const launch = buildTerminalLaunch(shellCommand);

  if (!launch) {
    const error = new Error(
      'No supported terminal emulator was found (tried gnome-terminal, konsole, xfce4-terminal, xterm).'
    );

    logOutput(error.message);

    return Promise.resolve({ code: null, stdout: '', stderr: '', error, timedOut: false });
  }

  logOutput(
    `Running ${path.basename(launch.file)} (interactive window) (timeout ${INTERACTIVE_SETUP_TIMEOUT_MS}ms).`
  );

  return new Promise((resolve) => {
    let settled = false;
    let poller = null;
    let deadline = null;

    function cleanupFiles() {
      try { fs.unlinkSync(sentinelPath); } catch (cleanupError) { /* already gone */ }
      try { fs.unlinkSync(pidPath); } catch (cleanupError) { /* already gone */ }
    }

    function finish(result) {
      if (settled) {
        return;
      }

      settled = true;

      if (poller) {
        clearInterval(poller);
      }

      if (deadline) {
        clearTimeout(deadline);
      }

      cleanupFiles();
      resolve(result);
    }

    let launchProcess;

    try {
      launchProcess = spawn(launch.file, launch.args, { stdio: 'pipe' });
    } catch (spawnError) {
      logOutput(`${path.basename(launch.file)} failed to start: ${spawnError.message}`);
      finish({ code: null, stdout: '', stderr: '', error: spawnError, timedOut: false });
      return;
    }

    let launchStderr = '';

    launchProcess.stderr.on('data', (chunk) => {
      launchStderr += chunk.toString();
    });

    launchProcess.once('error', (error) => {
      logOutput(`${path.basename(launch.file)} process error: ${error.message}`);
      finish({ code: null, stdout: '', stderr: '', error, timedOut: false });
    });

    launchProcess.once('close', (launchCode) => {
      if (settled) {
        return;
      }

      // Some terminal emulators (eg. gnome-terminal, which hands the
      // command off to an already-running instance) exit almost
      // immediately - well before the launched command finishes. A
      // non-zero exit here only means the terminal itself failed to
      // start, not that the script inside it failed.
      if (launchCode !== 0) {
        logOutput(`${path.basename(launch.file)} exited with code ${launchCode}: ${launchStderr.trim()}`);

        finish({
          code: launchCode,
          stdout: '',
          stderr: launchStderr,
          error: new Error(`Failed to open a terminal window: ${launchStderr.trim() || 'unknown error'}`),
          timedOut: false
        });

        return;
      }

      poller = setInterval(() => {
        if (!fs.existsSync(sentinelPath)) {
          return;
        }

        let code = null;

        try {
          code = parseInt(fs.readFileSync(sentinelPath, 'utf8').trim(), 10);
        } catch (readError) {
          code = null;
        }

        logOutput(`Interactive setup finished with exit code ${code}.`);

        finish({
          code,
          stdout: '',
          stderr: '',
          error: code === 0 ? null : new Error(`Interactive setup exited with code ${code}.`),
          timedOut: false
        });
      }, 1000);

      deadline = setTimeout(() => {
        logOutput(`Interactive setup timed out after ${INTERACTIVE_SETUP_TIMEOUT_MS}ms. Terminating.`);

        let pid = null;

        try {
          pid = parseInt(fs.readFileSync(pidPath, 'utf8').trim(), 10);
        } catch (readError) {
          pid = null;
        }

        if (pid) {
          killProcessTree(pid);
        }

        finish({
          code: null,
          stdout: '',
          stderr: '',
          error: new Error(`Interactive setup timed out after ${INTERACTIVE_SETUP_TIMEOUT_MS}ms.`),
          timedOut: true
        });
      }, INTERACTIVE_SETUP_TIMEOUT_MS);
    });
  });
}

async function setupHost(context, selectedHost) {
  const host = selectedHost.host;

  logOutput(`Setup / Repair requested for host="${host}" hostname="${selectedHost.hostname}".`);

  const initialTest = await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: `SSH Key Manager: ${host}`,
      cancellable: false
    },
    async (progress) => {
      progress.report({ message: 'Checking current SSH authentication...' });
      return testPasswordless(host);
    }
  );

  if (initialTest.success) {
    logOutput(`Existing key authentication works for ${host}.`);

    const result = await vscode.window.withProgress(
      {
        location: vscode.ProgressLocation.Notification,
        title: `SSH Key Manager: ${host}`,
        cancellable: false
      },
      async (progress) => {
        progress.report({ message: 'Running Setup / Repair...' });
        return runHiddenSetup(context, host);
      }
    );

    if (result.error) {
      logOutput(`Setup / Repair FAILED for ${host}: ${formatFailure(result)}`);

      vscode.window.showErrorMessage(
        `SSH Key Manager: Setup / Repair failed for ${host}. See SSH Key Manager Output for details.`
      );

      return;
    }

    logOutput(`Setup / Repair completed successfully for ${host}.`);

    vscode.window.showInformationMessage(
      `SSH Key Manager: Setup / Repair completed successfully for ${host}.`
    );

    return;
  }

  // A failed initial test (eg. "Permission denied (publickey,password)") is
  // the normal, expected state for a server that has not been set up yet -
  // it must fall through to the interactive password flow rather than being
  // treated as a final failure.
  logOutput(`Public-key authentication is not currently working for ${host}.`);

  const answer = await vscode.window.showQuickPick(
    [
      {
        label: '$(key) Continue',
        description: `Open a local ${TERMINAL_WINDOW_LABEL} window for the server password`,
        action: 'continue'
      },
      {
        label: '$(close) Cancel',
        action: 'cancel'
      }
    ],
    {
      title: `Password required for ${host}`,
      placeHolder: 'The password is handled directly by OpenSSH'
    }
  );

  if (!answer || answer.action !== 'continue') {
    logOutput(`Setup / Repair cancelled for ${host}.`);
    return;
  }

  vscode.window.setStatusBarMessage(
    `$(key) SSH Key Manager: complete the password prompt in the opened ${TERMINAL_WINDOW_LABEL} window for ${host}.`,
    15000
  );

  const result = await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: `SSH Key Manager: ${host}`,
      cancellable: false
    },
    async (progress) => {
      progress.report({
        message: `Waiting for the password prompt in the opened ${TERMINAL_WINDOW_LABEL} window...`
      });

      return runInteractiveSetup(context, host, false);
    }
  );

  if (result.error) {
    logOutput(`Setup / Repair FAILED for ${host}: ${formatFailure(result)}`);

    vscode.window.showErrorMessage(
      `SSH Key Manager: Setup / Repair failed for ${host}. See SSH Key Manager Output for details.`
    );

    return;
  }

  logOutput(`Interactive setup exited successfully for ${host}. Verifying key authentication.`);

  const finalTest = await testPasswordless(host);

  if (!finalTest.success) {
    logOutput(`Final passwordless SSH test FAILED for ${host}.`);

    vscode.window.showErrorMessage(
      `SSH Key Manager: Setup / Repair failed for ${host}. See SSH Key Manager Output for details.`
    );

    return;
  }

  logOutput(`Setup / Repair completed successfully for ${host}.`);

  vscode.window.showInformationMessage(
    `SSH Key Manager: Setup / Repair completed successfully for ${host}.`
  );
}

async function testHost(selectedHost) {
  const host = selectedHost.host;

  logOutput(`Passwordless SSH test requested for host="${host}" hostname="${selectedHost.hostname}".`);

  const { success, result } = await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: `SSH Key Manager: ${host}`,
      cancellable: false
    },
    async (progress) => {
      progress.report({ message: 'Testing passwordless SSH...' });
      return testPasswordless(host);
    }
  );

  if (!success) {
    logOutput(`Passwordless SSH test FAILED for ${host}: ${formatFailure(result)}`);

    vscode.window.showErrorMessage(
      `SSH Key Manager: Passwordless SSH is not working for ${host}. See SSH Key Manager Output for details.`
    );

    return;
  }

  logOutput(`Passwordless SSH test succeeded for ${host}.`);

  vscode.window.showInformationMessage(
    `SSH Key Manager: Passwordless SSH works for ${host}.`
  );
}

async function regenerateHost(context, selectedHost) {
  const host = selectedHost.host;

  const confirm = await vscode.window.showWarningMessage(
    `Regenerate the SSH key for ${host}? A backup will be created first.`,
    { modal: true },
    'Regenerate'
  );

  if (confirm !== 'Regenerate') {
    logOutput(`Key regeneration cancelled for ${host}.`);
    return;
  }

  logOutput(`Key regeneration requested for host="${host}" hostname="${selectedHost.hostname}".`);

  vscode.window.setStatusBarMessage(
    `$(key) SSH Key Manager: complete any prompts in the opened ${TERMINAL_WINDOW_LABEL} window for ${host}.`,
    15000
  );

  const result = await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: `SSH Key Manager: ${host}`,
      cancellable: false
    },
    async (progress) => {
      progress.report({
        message: `Waiting for key regeneration to finish in the opened ${TERMINAL_WINDOW_LABEL} window...`
      });

      return runInteractiveSetup(context, host, true);
    }
  );

  if (result.error) {
    logOutput(`Key regeneration FAILED for ${host}: ${formatFailure(result)}`);

    vscode.window.showErrorMessage(
      `SSH Key Manager: Key regeneration failed for ${host}. See SSH Key Manager Output for details.`
    );

    return;
  }

  const finalTest = await testPasswordless(host);

  if (!finalTest.success) {
    logOutput(`Regeneration finished but the final SSH test FAILED for ${host}.`);

    vscode.window.showErrorMessage(
      `SSH Key Manager: Key regeneration failed for ${host}. See SSH Key Manager Output for details.`
    );

    return;
  }

  logOutput(`SSH key regenerated successfully for ${host}.`);

  vscode.window.showInformationMessage(
    `SSH Key Manager: SSH key regenerated successfully for ${host}.`
  );
}

async function runManager(context) {
  if (!IS_WINDOWS && !IS_POSIX) {
    vscode.window.showErrorMessage(
      'SSH Key Manager currently supports Windows, macOS, and Linux as the local VS Code client.'
    );

    return;
  }

  if (!fs.existsSync(SSH_EXE)) {
    vscode.window.showErrorMessage(`OpenSSH client was not found at ${SSH_EXE}.`);
    return;
  }

  const selectedHost = await pickHost();

  if (!selectedHost) {
    return;
  }

  const action = await vscode.window.showQuickPick(
    [
      {
        label: '$(key) Setup / Repair',
        description: 'Create or reuse a dedicated key and repair SSH config',
        action: 'setup'
      },
      {
        label: '$(check) Test',
        description: 'Test public-key authentication',
        action: 'test'
      },
      {
        label: '$(sync) Regenerate Key',
        description: 'Back up and replace the SSH key',
        action: 'regenerate'
      }
    ],
    {
      title: `${selectedHost.host} -> ${selectedHost.hostname}`,
      placeHolder: 'Select an action'
    }
  );

  if (!action) {
    return;
  }

  logOutput(`Action selected: ${action.action} for ${selectedHost.host}.`);

  if (action.action === 'setup') {
    await setupHost(context, selectedHost);
    return;
  }

  if (action.action === 'test') {
    await testHost(selectedHost);
    return;
  }

  if (action.action === 'regenerate') {
    await regenerateHost(context, selectedHost);
  }
}

function activate(context) {
  outputChannel = vscode.window.createOutputChannel('SSH Key Manager');
  context.subscriptions.push(outputChannel);

  logOutput('SSH Key Manager activated.');

  context.subscriptions.push(
    vscode.commands.registerCommand('sshKeyManager.open', () => runManager(context))
  );
}

function deactivate() {}

module.exports = {
  activate,
  deactivate
};
