// eslint-disable-next-line
type Listener = (data: any) => void;

class SocketManager {
  private static instance: SocketManager;
  private sockets = new Map<string, WebSocket>();
  private listeners = new Map<string, Set<Listener>>();
  private connected = new Map<string, boolean>();

  private constructor() {}

  static getInstance(): SocketManager {
    if (!SocketManager.instance) {
      SocketManager.instance = new SocketManager();
    }
    return SocketManager.instance;
  }

  connect(url: string): void {
    if (this.sockets.has(url)) return;

    const ws = new WebSocket(url);
    this.sockets.set(url, ws);
    this.connected.set(url, false);
    this.listeners.set(url, new Set());

    ws.addEventListener('open', () => {
      this.connected.set(url, true);
      console.log(`✅ Connected: ${url}`);
    });

    ws.addEventListener('message', (event) => {
      const handlers = this.listeners.get(url);
      if (handlers) {
        for (const handler of handlers) {
          try {
            handler(event.data);
          } catch (err) {
            console.error(`Handler error for ${url}:`, err);
          }
        }
      }
    });

    ws.addEventListener('close', () => {
      this.connected.set(url, false);
      console.warn(`⚠️ Disconnected: ${url}`);
    });

    ws.addEventListener('error', (err) => {
      console.error(`❌ Socket error for ${url}:`, err);
    });
  }

  subscribe(url: string, listener: Listener): void {
    if (!this.sockets.has(url)) {
      this.connect(url);
    }
    this.listeners.get(url)?.add(listener);
  }

  unsubscribe(url: string, listener: Listener): void {
    this.listeners.get(url)?.delete(listener);
  }

  // eslint-disable-next-line
  send(url: string, data: any): void {
    const ws = this.sockets.get(url);
    if (ws && this.connected.get(url)) {
      ws.send(typeof data === 'string' ? data : JSON.stringify(data));
    } else {
      console.warn(`⚠️ Cannot send: not connected to ${url}`);
    }
  }

  disconnect(url: string): void {
    const ws = this.sockets.get(url);
    if (ws) {
      ws.close();
      this.sockets.delete(url);
      this.listeners.delete(url);
      this.connected.delete(url);
    }
  }

  disconnectAll(): void {
    for (const url of this.sockets.keys()) {
      this.disconnect(url);
    }
  }
}

export const socket = SocketManager.getInstance();
