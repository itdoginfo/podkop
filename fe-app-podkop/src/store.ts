import { Podkop } from './podkop/types';

type Listener<T> = (next: T, prev: T, diff: Partial<T>) => void;

// eslint-disable-next-line
class Store<T extends Record<string, any>> {
  private value: T;
  private listeners = new Set<Listener<T>>();

  constructor(initial: T) {
    this.value = initial;
  }

  get(): T {
    return this.value;
  }

  set(next: Partial<T>): void {
    const prev = this.value;
    const merged = { ...this.value, ...next };
    if (Object.is(prev, merged)) return;

    this.value = merged;

    const diff: Partial<T> = {};
    for (const key in merged) {
      if (merged[key] !== prev[key]) diff[key] = merged[key];
    }

    this.listeners.forEach((cb) => cb(this.value, prev, diff));
  }

  subscribe(cb: Listener<T>): () => void {
    this.listeners.add(cb);
    cb(this.value, this.value, {}); // первый вызов без diff
    return () => this.listeners.delete(cb);
  }

  patch<K extends keyof T>(key: K, value: T[K]): void {
    this.set({ ...this.value, [key]: value });
  }

  getKey<K extends keyof T>(key: K): T[K] {
    return this.value[key];
  }

  subscribeKey<K extends keyof T>(
    key: K,
    cb: (value: T[K]) => void,
  ): () => void {
    let prev = this.value[key];
    const unsub = this.subscribe((val) => {
      if (val[key] !== prev) {
        prev = val[key];
        cb(val[key]);
      }
    });
    return unsub;
  }
}

export const store = new Store<{
  sections: Podkop.OutboundGroup[];
  traffic: { up: number; down: number };
  memory: { inuse: number; oslimit: number };
  connections: {
    connections: unknown[];
    downloadTotal: number;
    memory: number;
    uploadTotal: number;
  };
  services: {
    singbox: number;
    podkop: number;
  };
}>({
  sections: [],
  traffic: { up: 0, down: 0 },
  memory: { inuse: 0, oslimit: 0 },
  connections: { connections: [], memory: 0, downloadTotal: 0, uploadTotal: 0 },
  services: { singbox: -1, podkop: -1 },
});
