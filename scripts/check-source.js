'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const root = path.resolve(__dirname, '..');
const ignored = new Set(['.git', 'node_modules']);
const textExtensions = new Set([
  '.js', '.json', '.md', '.ps1', '.yml', '.yaml', '.txt', '.gitignore', '.vscodeignore'
]);

const suspicious = [
  { label: 'absolute Windows user profile path', regex: /C:\\Users\\[^<%$\s]+/i },
  { label: 'RFC1918 10/8 address', regex: /\b10(?:\.\d{1,3}){3}\b/ },
  { label: 'RFC1918 172.16/12 address', regex: /\b172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2}\b/ },
  { label: 'RFC1918 192.168/16 address', regex: /\b192\.168(?:\.\d{1,3}){2}\b/ },
  { label: 'UTF-8 byte-order mark', regex: /\uFEFF/ },
  { label: 'mojibake (misdecoded UTF-8)', regex: /Ã[\x80-\xBF]|â€[\x80-\x9F\x94]/ }
];

function walk(dir) {
  const out = [];

  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (ignored.has(entry.name)) continue;

    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...walk(full));
    } else {
      out.push(full);
    }
  }

  return out;
}

function checkHygiene() {
  let failed = false;

  for (const file of walk(root)) {
    const ext = path.extname(file);
    const base = path.basename(file);
    if (!textExtensions.has(ext) && !textExtensions.has(base)) continue;

    const text = fs.readFileSync(file, 'utf8');
    for (const rule of suspicious) {
      if (rule.regex.test(text)) {
        failed = true;
        console.error(`[sanitize] ${rule.label}: ${path.relative(root, file)}`);
      }
    }
  }

  if (failed) {
    console.error('Source hygiene check FAILED.');
  } else {
    console.log('Source hygiene check passed.');
  }

  return !failed;
}

function checkJavaScriptSyntax() {
  const entry = path.join(root, 'extension.js');

  try {
    execFileSync(process.execPath, ['--check', entry], { stdio: 'pipe' });
    console.log('JavaScript syntax check passed.');
    return true;
  } catch (error) {
    console.error('JavaScript syntax check FAILED.');
    console.error(error.stderr ? error.stderr.toString() : error.message);
    return false;
  }
}

function checkPowerShellSyntax() {
  const script = path.join(root, 'scripts', 'setup-ssh-key.ps1');

  if (process.platform !== 'win32') {
    console.log('Skipping PowerShell syntax check (not running on Windows).');
    return true;
  }

  const windowsRoot = process.env.SystemRoot || 'C:\\Windows';
  const powershell = path.join(
    windowsRoot,
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe'
  );

  if (!fs.existsSync(powershell)) {
    console.log('Skipping PowerShell syntax check (powershell.exe not found).');
    return true;
  }

  const command =
    `$content = Get-Content -LiteralPath '${script}' -Raw; ` +
    `[void][scriptblock]::Create($content)`;

  try {
    execFileSync(
      powershell,
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', command],
      { stdio: 'pipe' }
    );
    console.log('PowerShell syntax check passed.');
    return true;
  } catch (error) {
    console.error('PowerShell syntax check FAILED.');
    console.error(error.stderr ? error.stderr.toString() : error.message);
    return false;
  }
}

const results = [
  checkJavaScriptSyntax(),
  checkPowerShellSyntax(),
  checkHygiene()
];

if (results.some((ok) => !ok)) {
  process.exit(1);
}
