const http = require('http');

const workerIps = ['10.40.101.184', '10.40.101.185', '10.40.101.186'];
const hostHeader = 'chat.infra.internal';
const concurrency = 60; // 60 concurrent worker loops
const durationSec = 180; // 3 minutes for HPA scaling & Chaos

const agents = workerIps.map(ip => new http.Agent({
  keepAlive: true,
  maxSockets: 50
}));

let totalSuccess = 0;
let totalFailed = 0;
let running = true;
let reqIndex = 0;
const startTime = Date.now();

console.log(`================================================================`);
console.log(`  Enterprise K8s Module 4: High-Concurrency Load & Chaos Generator`);
console.log(`  Target IPs: ${workerIps.join(', ')} (Host: ${hostHeader})`);
console.log(`  Concurrency: ${concurrency} parallel streams | Duration: ${durationSec}s`);
console.log(`================================================================`);

function sendRequest() {
  if (!running) return;
  const ipIdx = (reqIndex++) % workerIps.length;
  const targetIp = workerIps[ipIdx];
  const agent = agents[ipIdx];

  const req = http.get({
    host: targetIp,
    port: 80,
    path: '/',
    headers: { 'Host': hostHeader },
    agent,
    timeout: 2000
  }, (res) => {
    res.resume();
    if (res.statusCode >= 200 && res.statusCode < 400) {
      totalSuccess++;
    } else {
      totalFailed++;
    }
    if (running) setImmediate(sendRequest);
  });

  req.on('error', (err) => {
    totalFailed++;
    if (running) setTimeout(sendRequest, 100);
  });

  req.on('timeout', () => {
    req.destroy();
    totalFailed++;
    if (running) setTimeout(sendRequest, 100);
  });
}

// Spawn concurrent workers
for (let i = 0; i < concurrency; i++) {
  sendRequest();
}

// Print stats every 3 seconds
const statsInterval = setInterval(() => {
  const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
  const total = totalSuccess + totalFailed;
  const rps = (total / elapsed).toFixed(0);
  const errRate = total > 0 ? ((totalFailed / total) * 100).toFixed(2) : '0.00';
  console.log(`[T+${elapsed.padStart(5)}s] Total: ${String(total).padStart(6)} | 200 OK: ${String(totalSuccess).padStart(6)} | Failed: ${String(totalFailed).padStart(2)} | RPS: ${String(rps).padStart(4)}/s | ErrRate: ${errRate}%`);
}, 3000);

// Stop after duration
setTimeout(() => {
  running = false;
  clearInterval(statsInterval);
  agents.forEach(a => a.destroy());
  const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
  const total = totalSuccess + totalFailed;
  const rps = (total / elapsed).toFixed(0);
  console.log(`\n================ LOAD GENERATION COMPLETED ================`);
  console.log(`Duration: ${elapsed}s | Total Requests: ${total} | RPS: ${rps}/s | Success: ${totalSuccess} | Failed: ${totalFailed}`);
  process.exit(0);
}, durationSec * 1000);
