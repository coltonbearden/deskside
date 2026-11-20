// A stand-in for MeshCentral's meshctrl.js, for tests/HealthSweep.Tests.ps1. It records how it was called (argv and
// the MESHCTRL_* login variables) to STUB_LOG, one JSON line per call, and answers from environment variables:
//   STUB_LIST   'ok' (default): print STUB_DEVICES (a JSON array) as `listdevices --json` would;
//               'denied': print "Invalid login." as meshctrl does, still with exit code 0.
//   STUB_RUN    'ok' (default): print a few lines, then 'DESKSIDE-HEALTH ' and STUB_HEALTH (compact JSON);
//               'hang': never answer (an agent already busy with a command); 'denied': print "Access denied".
//   STUB_PAD    pad the health JSON with a string of this many characters (a long reply).
const fs = require('fs');
const argv = process.argv.slice(2);
const log = process.env.STUB_LOG;
if (log) {
  fs.appendFileSync(log, JSON.stringify({
    argv: argv,
    env: { url: process.env.MESHCTRL_URL || null, user: process.env.MESHCTRL_LOGINUSER || null, pass: process.env.MESHCTRL_LOGINPASS || null }
  }) + '\n');
}
const cmd = argv[0];
if (cmd === 'listdevices') {
  if ((process.env.STUB_LIST || 'ok') === 'denied') { console.log('Invalid login.'); process.exit(); }
  console.log(JSON.stringify(JSON.parse(process.env.STUB_DEVICES || '[]'), null, 2));
  process.exit();
}
if (cmd === 'runcommand') {
  const mode = process.env.STUB_RUN || 'ok';
  if (mode === 'hang') { setInterval(function () { }, 1000); }
  else if (mode === 'denied') { console.log('Access denied'); process.exit(); }
  else {
    const health = JSON.parse(process.env.STUB_HEALTH || '{"schema":"deskside.health/v1","findings":[],"data":{}}');
    const pad = parseInt(process.env.STUB_PAD || '0', 10);
    if (pad > 0) { health.pad = 'x'.repeat(pad); }
    console.log('Windows PowerShell\r\nCopyright (C) Microsoft Corporation.\r\n');
    console.log('DESKSIDE-HEALTH ' + JSON.stringify(health));
    process.exit();
  }
} else {
  console.log('unknown command');
  process.exit();
}
