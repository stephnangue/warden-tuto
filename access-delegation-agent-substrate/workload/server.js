// The agent's server. Each request runs one prompt with Claude Code, for the
// person whose token comes with it. The server holds that token for the length
// of the run and never hands it to Claude Code: Claude Code's tools reach
// GitHub and Kubernetes through the local gateway below, which adds the token
// on the way out. Claude Code runs as another user, so it cannot read this
// process's memory either. Each run gets a fresh home, and when it ends the
// server stops everything it left running and deletes everything it wrote, so
// nothing of one person's run reaches the next. If that clean-up fails, the
// agent refuses further work rather than carry anything over.
//
//   :80              POST /prompt   X-User-Token: <the person's JWT>; body: the prompt
//                    GET  /healthz  ok (the template's wakeup probe)
//   127.0.0.1:8081   the local gateway, for Claude Code's tools:
//                    /git/...        Warden's GitHub provider (clone, fetch, push)
//                    /github-mcp...  GitHub's MCP server, through Warden
//                    /k8s/...        the Kubernetes API, through Warden
const fs = require('node:fs');
const http = require('node:http');
const { spawn, execFileSync } = require('node:child_process');

const MODEL = process.env.MODEL || 'haiku';
const WARDEN = new URL(process.env.WARDEN_ON_BEHALF_URL);
const ROUTES = {
  'git': process.env.GIT_GATEWAY_PATH,
  'github-mcp': process.env.GITHUB_MCP_GATEWAY_PATH,
  'k8s': process.env.K8S_GATEWAY_PATH,
};
const AGENT_UID = 1000; // the image's node user
const AGENT_GID = 1000;
const TIMEOUT_MS = 600_000;
const MAX_PROMPT_BYTES = 64 * 1024;
const JWT = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;
const NAME = /^[A-Za-z0-9._-]{1,64}$/;

// The person's token while a prompt runs; null between runs.
let runToken = null;
let busy = false;
// Why this agent refuses further runs, once a run's leftovers could not be removed.
let tainted = '';
// The gateway's calls to Warden during the current run, cut when it ends.
const inflight = new Set();

function send(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end(body);
}

function sleepMs(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// A run's home is a copy of the image's /opt/agent-home. The agent user makes
// and deletes it: this root process has no CHOWN or FOWNER capability, so it
// could neither hand a folder over nor delete one the agent user owns.
function asAgent(cmd, args) {
  return execFileSync(cmd, args, { uid: AGENT_UID, gid: AGENT_GID, encoding: 'utf8' }).trim();
}

function newRunHome() {
  return asAgent('sh', ['-c', 'd=$(mktemp -d /tmp/run-XXXXXX) && cp -R /opt/agent-home/. "$d" && echo "$d"']);
}

// The places the agent user can write. The image leaves it no others.
const AGENT_WRITABLE = ['/tmp', '/var/tmp', '/run/lock', '/dev/shm'];

// agentProcessesLeft counts the agent user's live processes. Killed ones wait
// as zombies until they are reaped, and can no longer run.
function agentProcessesLeft() {
  let left = 0;
  for (const pid of fs.readdirSync('/proc')) {
    if (!/^\d+$/.test(pid)) continue;
    let status;
    try { status = fs.readFileSync(`/proc/${pid}/status`, 'utf8'); } catch { continue; }
    const uid = /^Uid:\s+(\d+)/m.exec(status);
    const state = /^State:\s+(\S)/m.exec(status);
    if (uid && uid[1] === String(AGENT_UID) && !(state && state[1] === 'Z')) left++;
  }
  return left;
}

// stopAgentProcesses stops everything the run left running. Such a process
// could call the local gateway during the next run, with the next person's
// token, and it holds the output pipe open, which would keep the run from ever
// finishing. kill -1 reaches every process of the agent user, but a process
// forked during one pass survives it, so passes repeat until none is left.
function stopAgentProcesses() {
  for (let pass = 0; pass < 20; pass++) {
    try { asAgent('sh', ['-c', 'kill -9 -1 2>/dev/null; true']); } catch { /* checked below */ }
    if (agentProcessesLeft() === 0) return true;
    sleepMs(50);
  }
  return false;
}

// clearAgentFiles deletes everything the run wrote, its home included, so no
// file hands one person's data to the next. A run can make its directories
// read-only, which would keep their contents from being deleted, so their
// permissions are restored first. It reports whether anything is left.
function clearAgentFiles() {
  const owned = [...AGENT_WRITABLE, '-mindepth', '1', '-user', String(AGENT_UID)];
  try { asAgent('find', [...AGENT_WRITABLE, '-mindepth', '1', '-maxdepth', '1', '-user', String(AGENT_UID), '-exec', 'chmod', '-R', 'u+rwX', '{}', '+']); } catch { /* checked below */ }
  try { asAgent('find', [...owned, '-delete']); } catch { /* checked below */ }
  try { return asAgent('find', owned) === ''; } catch { return false; }
}

// endRun closes a run: it cuts the gateway's calls still in flight, then stops
// what the run left running and deletes what it wrote. When either fails, the
// agent refuses further runs until it is recreated.
function endRun() {
  runToken = null;
  for (const upstream of inflight) upstream.destroy();
  inflight.clear();
  const stopped = stopAgentProcesses();
  const cleared = clearAgentFiles();
  if (!stopped || !cleared) {
    tainted = `a run left ${stopped ? 'files' : 'processes'} that could not be removed`;
    console.log(`[agent] refusing further runs: ${tainted}`);
  }
  busy = false;
}

// personOf names the person for Claude Code and git. Warden verifies the
// token; this only reads its sub, and falls back to a neutral name.
function personOf(token) {
  try {
    const sub = JSON.parse(Buffer.from(token.split('.')[1], 'base64url')).sub;
    return NAME.test(sub) ? sub : 'the-person';
  } catch {
    return 'the-person';
  }
}

// Headers the gateway never forwards: connection-level ones, credentials, and
// every header that steers Warden (X-Warden-Role and the like), so the role,
// namespace and identities of a call are only the gateway's own.
const DROP = new Set(['host', 'connection', 'keep-alive', 'proxy-connection', 'te', 'trailer',
  'upgrade', 'proxy-authorization', 'authorization', 'dpop']);

http.createServer((req, res) => {
  const m = req.url.match(/^\/([a-z0-9-]+)(\/.*|\?.*)?$/);
  const base = m && ROUTES[m[1]];
  if (!base) return send(res, 404, 'no such route\n');
  // A dot segment or an encoded dot, slash or backslash could climb out of the
  // route's Warden path once normalized. Warden refuses them too; no tool needs one.
  const rest = m[2] || '';
  if (/(^|\/)\.{1,2}(\/|\?|$)/.test(rest) || /%2e|%2f|%5c/i.test(rest)) return send(res, 400, 'path not allowed\n');
  if (!runToken) return send(res, 403, 'no prompt is running\n');
  const headers = {};
  for (const [k, v] of Object.entries(req.headers)) {
    if (!DROP.has(k) && !k.startsWith('x-warden-')) headers[k] = v;
  }
  headers['authorization'] = `Bearer ${runToken}`;
  // The egress gateway replaces this placeholder with the actor JWT.
  headers['x-warden-agent-token'] = 'placeholder';
  const upstream = http.request({
    host: WARDEN.hostname, port: WARDEN.port, method: req.method,
    path: base + rest, headers,
  }, (up) => {
    res.writeHead(up.statusCode, up.headers);
    up.pipe(res);
  });
  inflight.add(upstream);
  upstream.on('close', () => inflight.delete(upstream));
  upstream.on('error', (err) => {
    if (res.headersSent) return res.destroy();
    send(res, 502, `cannot reach Warden: ${err.message}\n`);
  });
  // A caller that goes away takes its call to Warden with it.
  res.on('close', () => { if (!res.writableFinished) upstream.destroy(); });
  req.pipe(upstream);
}).listen(8081, '127.0.0.1');

function runClaude(prompt, token, res) {
  const person = personOf(token);
  let out = '';
  let home;
  try {
    home = newRunHome();
  } catch (err) {
    busy = false;
    return send(res, 500, `cannot prepare the run's home: ${err.message}\n`);
  }
  runToken = token;
  let done = false;
  const finish = (status) => {
    if (done) return;
    done = true;
    endRun();
    console.log(`[agent] answered ${status}`);
    send(res, status, out);
  };
  const args = ['--print', '--model', MODEL,
    '--append-system-prompt', `You are acting for ${person}.`,
    '--allowedTools', 'Bash', 'Read', 'Write', 'Edit', 'Glob', 'Grep', 'mcp__warden', 'mcp__github'];
  // A fresh environment: nothing of this process's, and no token.
  const env = {
    HOME: home, USER: 'node', PATH: process.env.PATH,
    ANTHROPIC_BASE_URL: process.env.ANTHROPIC_BASE_URL,
    ANTHROPIC_AUTH_TOKEN: 'placeholder',
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
    GIT_TERMINAL_PROMPT: '0',
    GIT_AUTHOR_NAME: `Claude Code for ${person}`,
    GIT_AUTHOR_EMAIL: `${person}-agent@users.noreply.github.com`,
    GIT_COMMITTER_NAME: `Claude Code for ${person}`,
    GIT_COMMITTER_EMAIL: `${person}-agent@users.noreply.github.com`,
  };
  // Switching to the agent user needs SETUID and SETGID, which the template
  // grants; without them spawn throws, and the run fails instead of the server.
  // The cd happens after the switch, in sh: spawn's own cwd is entered while
  // still root, and root here has no DAC_OVERRIDE to enter the private home.
  let claude;
  try {
    claude = spawn('sh', ['-c', 'cd "$HOME/work" && exec claude "$@"', 'claude', ...args],
      { env, uid: AGENT_UID, gid: AGENT_GID, timeout: TIMEOUT_MS, killSignal: 'SIGKILL' });
  } catch (err) {
    out += `cannot start claude: ${err.message}\n`;
    return finish(500);
  }
  claude.stdout.on('data', (c) => { out += c; });
  claude.stderr.on('data', (c) => { out += c; });
  claude.on('error', (err) => { out += `cannot run claude: ${err.message}\n`; finish(500); });
  claude.on('exit', stopAgentProcesses);
  claude.on('close', (code) => finish(code === 0 ? 200 : 502));
  // The prompt goes on stdin: --allowedTools takes a list and would swallow
  // an argument placed after it.
  claude.stdin.end(prompt);
}

// The self-check, for templates that set SELF_CHECK=1: with a person's token
// loaded as for a prompt, a fixed script running as the agent user looks for
// that token everywhere Claude Code could. Nothing it runs comes from the request.
const SELF_CHECK = `
cd "$HOME/work" || exit 1
id
echo "--- environment entries holding eyJ: $(env | grep -c eyJ)"
echo "--- processes:"
for p in /proc/[0-9]*; do
  echo "  pid $(basename "$p") uid $(awk '/^Uid/ {print $2}' "$p/status") : $(tr '\\0' ' ' < "$p/cmdline" 2>/dev/null)"
done
echo "--- files under ~, /tmp, /var/tmp, /run/lock, /dev/shm, /opt holding eyJ:"
grep -rl eyJ ~ /tmp /var/tmp /run/lock /dev/shm /opt 2>/dev/null; echo "  (end)"
echo "--- files of the agent user left by earlier runs:"
find /tmp /var/tmp /run/lock /dev/shm -user 1000 2>/dev/null | grep -v "^$HOME"; echo "  (end)"
echo "--- the template home: $(touch /opt/agent-home/.claude/CLAUDE.md 2>/dev/null && echo WRITABLE || echo read-only)"
echo "--- the server's /proc/$SERVER_PID/environ:"; cat /proc/$SERVER_PID/environ 2>&1 | head -c 120; echo
echo "--- the server's /proc/$SERVER_PID/mem:"; dd if=/proc/$SERVER_PID/mem of=/dev/null bs=4096 count=1 skip=1024 2>&1 | head -1
echo "--- dot-segment path through the gateway:"; curl -s --path-as-is http://127.0.0.1:8081/k8s/../../v1/sys/mcp
echo "--- a role header through the gateway (kube-ops still answers):"
curl -s -H 'X-Warden-Role: github-tools' http://127.0.0.1:8081/k8s/version | grep -o '"gitVersion": *"[^"]*"' || echo "  refused"
echo "--- the gateway works meanwhile:"; kubectl auth whoami 2>&1 | head -3
`;

function runSelfCheck(token, res) {
  let out = '';
  let home;
  try {
    home = newRunHome();
  } catch (err) {
    busy = false;
    return send(res, 500, `cannot prepare the run's home: ${err.message}\n`);
  }
  runToken = token;
  let done = false;
  const finish = () => {
    if (done) return;
    done = true;
    endRun();
    send(res, 200, out);
  };
  let check;
  try {
    check = spawn('sh', ['-c', SELF_CHECK], { uid: AGENT_UID, gid: AGENT_GID, killSignal: 'SIGKILL',
      env: { HOME: home, USER: 'node', PATH: process.env.PATH, SERVER_PID: String(process.pid) }, timeout: 60_000 });
  } catch (err) {
    out += `cannot start the check: ${err.message}\n`;
    return finish();
  }
  check.stdout.on('data', (c) => { out += c; });
  check.stderr.on('data', (c) => { out += c; });
  check.on('error', (err) => { out += `cannot run the check: ${err.message}\n`; finish(); });
  check.on('exit', stopAgentProcesses);
  check.on('close', finish);
}

http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/healthz') {
    return tainted ? send(res, 503, `${tainted}; recreate this agent\n`) : send(res, 200, 'ok\n');
  }
  const selfCheck = process.env.SELF_CHECK === '1' && req.method === 'POST' && req.url === '/self-check';
  if (!selfCheck && (req.method !== 'POST' || req.url !== '/prompt')) {
    return send(res, 404, 'POST /prompt with the prompt as the body\n');
  }
  const token = req.headers['x-user-token'] || '';
  if (!JWT.test(token)) return send(res, 400, 'X-User-Token must carry the JWT of the person this prompt is for\n');
  // The run starts only once the whole prompt has arrived: a caller that goes
  // away mid-upload leaves nothing behind.
  const chunks = [];
  let size = 0;
  let tooLarge = false;
  req.on('data', (c) => {
    size += c.length;
    if (size <= MAX_PROMPT_BYTES) return chunks.push(c);
    if (!tooLarge) {
      tooLarge = true;
      res.on('finish', () => req.destroy());
      send(res, 413, 'prompt too large\n');
    }
  });
  req.on('end', () => {
    if (tooLarge) return;
    if (tainted) return send(res, 503, `${tainted}; recreate this agent\n`);
    if (busy) return send(res, 409, 'busy with another prompt\n');
    if (selfCheck) {
      busy = true;
      return runSelfCheck(token, res);
    }
    const prompt = Buffer.concat(chunks).toString('utf8');
    if (!prompt.trim()) return send(res, 400, 'empty prompt\n');
    busy = true;
    console.log(`[agent] prompt for ${personOf(token)}: ${prompt.trim().slice(0, 200)}`);
    runClaude(prompt, token, res);
  });
}).listen(80, () => console.log(`[agent] listening on :80, gateway on 127.0.0.1:8081, model ${MODEL}`));
