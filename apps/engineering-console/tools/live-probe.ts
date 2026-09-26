// Test tooling only: runs the Console's real RuntimeStreamClient against a
// live runtime stream and prints each snapshot as one JSON line on stdout.
// Usage: node --experimental-strip-types --import ./tools/ts-resolve.mjs \
//          tools/live-probe.ts <stream-url> [heartbeatTimeoutMs] [reconnectDelayMs]
import { RuntimeStreamClient, type LiveSnapshot } from '../src/runtime/liveStream';

const [url, heartbeat = '600', reconnect = '100'] = process.argv.slice(2);
if (!url) {
  process.stderr.write('stream url required\n');
  process.exit(2);
}

const client = new RuntimeStreamClient({
  url,
  heartbeatTimeoutMs: Number(heartbeat),
  reconnectDelayMs: Number(reconnect),
  onChange: (s: LiveSnapshot) => {
    const v = s.view;
    process.stdout.write(
      JSON.stringify({
        connection: s.connection,
        reason: s.reason,
        streamId: s.streamId,
        sessionId: v.sessionId,
        sessionState: v.sessionState,
        captionEnvironment: v.captionEnvironment,
        captionTruth: v.captionTruth,
        captions: v.captions,
        deviceState: v.deviceState,
        deviceEnvironment: v.deviceEnvironment,
        deviceTruth: v.deviceTruth,
        degraded: v.degraded,
        sequenceGaps: v.sequenceGaps,
      }) + '\n',
    );
  },
});
client.start();
process.on('SIGTERM', () => {
  client.stop();
  process.exit(0);
});
