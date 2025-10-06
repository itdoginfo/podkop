import { Podkop } from './podkop/types';

function jsonStableStringify<T, V>(obj: T): string {
  return JSON.stringify(obj, (_, value) => {
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      return Object.keys(value)
        .sort()
        .reduce(
          (acc, key) => {
            acc[key] = value[key];
            return acc;
          },
          {} as Record<string, V>,
        );
    }
    return value;
  });
}

function jsonEqual<A, B>(a: A, b: B): boolean {
  try {
    return jsonStableStringify(a) === jsonStableStringify(b);
  } catch {
    return false;
  }
}

type Listener<T> = (next: T, prev: T, diff: Partial<T>) => void;

// eslint-disable-next-line
class Store<T extends Record<string, any>> {
  private value: T;
  private readonly initial: T;
  private listeners = new Set<Listener<T>>();
  private lastHash = '';

  constructor(initial: T) {
    this.value = initial;
    this.initial = structuredClone(initial);
    this.lastHash = jsonStableStringify(initial);
  }

  get(): T {
    return this.value;
  }

  set(next: Partial<T>): void {
    const prev = this.value;
    const merged = { ...prev, ...next };

    if (jsonEqual(prev, merged)) return;

    this.value = merged;
    this.lastHash = jsonStableStringify(merged);

    const diff: Partial<T> = {};
    for (const key in merged) {
      if (!jsonEqual(merged[key], prev[key])) diff[key] = merged[key];
    }

    this.listeners.forEach((cb) => cb(this.value, prev, diff));
  }

  reset(): void {
    const prev = this.value;
    const next = structuredClone(this.initial);

    if (jsonEqual(prev, next)) return;

    this.value = next;
    this.lastHash = jsonStableStringify(next);

    const diff: Partial<T> = {};
    for (const key in next) {
      if (!jsonEqual(next[key], prev[key])) diff[key] = next[key];
    }

    this.listeners.forEach((cb) => cb(this.value, prev, diff));
  }

  subscribe(cb: Listener<T>): () => void {
    this.listeners.add(cb);
    cb(this.value, this.value, {});
    return () => this.listeners.delete(cb);
  }

  unsubscribe(cb: Listener<T>): void {
    this.listeners.delete(cb);
  }

  patch<K extends keyof T>(key: K, value: T[K]): void {
    this.set({ [key]: value } as unknown as Partial<T>);
  }

  getKey<K extends keyof T>(key: K): T[K] {
    return this.value[key];
  }

  subscribeKey<K extends keyof T>(
    key: K,
    cb: (value: T[K]) => void,
  ): () => void {
    let prev = this.value[key];
    const wrapper: Listener<T> = (val) => {
      if (!jsonEqual(val[key], prev)) {
        prev = val[key];
        cb(val[key]);
      }
    };
    this.listeners.add(wrapper);
    return () => this.listeners.delete(wrapper);
  }
}

export interface StoreType {
  tabService: {
    current: string;
    all: string[];
  };
  dashboardSections: {
    loading: boolean;
    data: Podkop.OutboundGroup[];
    failed: boolean;
  };
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
}

const initialStore: StoreType = {
  tabService: {
    current: '',
    all: [],
  },
  dashboardSections: {
    data: [],
    loading: true,
  },
  traffic: { up: -1, down: -1 },
  memory: { inuse: -1, oslimit: -1 },
  connections: {
    connections: [],
    memory: -1,
    downloadTotal: -1,
    uploadTotal: -1,
  },
  services: { singbox: -1, podkop: -1 },
};

export const store = new Store<StoreType>(initialStore);
