/**
 * Clash API metrics for the dev stand: /traffic and /connections on :9090.
 *
 * Handshake and framing are written by hand so node:22-alpine needs no
 * npm install.
 */
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';

const PORT = 9090;
const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/** Text frame: FIN + opcode 1, unmasked (servers do not mask). */
function encodeFrame(text) {
    const payload = Buffer.from(text, 'utf8');
    const length = payload.length;

    let header;

    if (length < 126) {
        header = Buffer.from([0x81, length]);
    } else if (length < 65536) {
        header = Buffer.alloc(4);
        header[0] = 0x81;
        header[1] = 126;
        header.writeUInt16BE(length, 2);
    } else {
        header = Buffer.alloc(10);
        header[0] = 0x81;
        header[1] = 127;
        header.writeBigUInt64BE(BigInt(length), 2);
    }

    return Buffer.concat([header, payload]);
}

const state = {
    uploadTotal: 4_800_000_000,
    downloadTotal: 51_200_000_000,
};

function trafficFrame() {
    return {
        up: Math.floor(20_000 + Math.random() * 900_000),
        down: Math.floor(80_000 + Math.random() * 6_000_000),
    };
}

function connectionsFrame() {
    state.uploadTotal += Math.floor(Math.random() * 900_000);
    state.downloadTotal += Math.floor(Math.random() * 6_000_000);

    return {
        uploadTotal: state.uploadTotal,
        downloadTotal: state.downloadTotal,
        memory: Math.floor(28_000_000 + Math.random() * 12_000_000),
        connections: Array.from(
            { length: 8 + Math.floor(Math.random() * 24) },
            (_unused, index) => ({ id: `conn-${index}` }),
        ),
    };
}

const server = createServer((req, res) => {
    // The dashboard only uses the websocket; GET just needs to say something
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ hello: 'podkop dev clash mock', path: req.url }));
});

server.on('upgrade', (req, socket) => {
    const key = req.headers['sec-websocket-key'];

    if (!key) {
        socket.destroy();
        return;
    }

    const accept = createHash('sha1')
        .update(key + GUID)
        .digest('base64');

    socket.write(
        'HTTP/1.1 101 Switching Protocols\r\n' +
            'Upgrade: websocket\r\n' +
            'Connection: Upgrade\r\n' +
            `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
    );

    const path = (req.url || '').split('?')[0];
    const build = path === '/traffic' ? trafficFrame : connectionsFrame;

    console.log(`[clash-mock] connected: ${path}`);

    const timer = setInterval(() => {
        socket.write(encodeFrame(JSON.stringify(build())));
    }, 1000);

    const stop = () => {
        clearInterval(timer);
        socket.destroy();
    };

    socket.on('close', stop);
    socket.on('error', stop);
});

server.listen(PORT, '0.0.0.0', () => {
    console.log(`[clash-mock] listening on :${PORT} (/traffic, /connections)`);
});
