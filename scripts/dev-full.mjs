import { spawn } from 'node:child_process';
import { readFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const root = process.cwd();
const envFile = path.join(root, '.env.local');

if (!existsSync(envFile)) {
  console.error('Missing .env.local');
  process.exit(1);
}

const fileEnv = Object.fromEntries(
  (await readFile(envFile, 'utf8')).split(/\r?\n/)
    .map(line => line.trim())
    .filter(line => line && !line.startsWith('#') && line.includes('='))
    .map(line => {
      const i = line.indexOf('=');
      return [
        line.slice(0, i).trim(),
        line.slice(i + 1).trim().replace(/^['"]|['"]$/g, '')
      ];
    })
);

const env = { ...process.env, ...fileEnv };

if (!env.VITE_SUPABASE_URL || !env.VITE_SUPABASE_PUBLISHABLE_KEY) {
  console.error('.env.local must define Supabase values.');
  process.exit(1);
}

const javaSource = path.join(
  root, 'backend-java', 'src', 'main', 'java',
  'com', 'hope2live', 'Hope2LiveApi.java'
);

const classes = path.join(root, 'backend-java', 'target', 'classes');
await mkdir(classes, { recursive: true });

const javac = spawn(
  'javac',
  ['--add-modules', 'jdk.httpserver', '-d', classes, javaSource],
  { cwd: root, stdio: 'inherit', env }
);

const compileCode = await new Promise(resolve => javac.on('close', resolve));

if (compileCode !== 0) process.exit(compileCode ?? 1);

const java = spawn(
  'java',
  ['--add-modules', 'jdk.httpserver', '-cp', classes, 'com.hope2live.Hope2LiveApi'],
  { cwd: root, stdio: 'inherit', env }
);

const npm = process.platform === 'win32'
  ? spawn(
      process.env.ComSpec || 'cmd.exe',
      ['/d', '/s', '/c', 'npm run dev'],
      { cwd: root, stdio: 'inherit', env, windowsHide: true }
    )
  : spawn('npm', ['run', 'dev'], { cwd: root, stdio: 'inherit', env });

let stopping = false;

const stop = () => {
  if (stopping) return;
  stopping = true;
  java.kill();
  npm.kill();
};

process.on('SIGINT', stop);
process.on('SIGTERM', stop);

for (const [name, child] of [['Java API', java], ['Vite', npm]]) {
  child.on('error', error => {
    console.error(`${name} failed to start: ${error.message}`);
    stop();
    process.exitCode = 1;
  });
}

java.on('close', code => {
  if (!stopping && code !== 0) {
    console.error('Java API stopped.');
    stop();
    process.exitCode = code ?? 1;
  }
});

npm.on('close', code => {
  if (!stopping) {
    stop();
    process.exitCode = code ?? 0;
  }
});