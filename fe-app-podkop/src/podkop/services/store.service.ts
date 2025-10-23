import { Podkop } from '../types';
import { initialDiagnosticStore } from '../tabs/diagnostic/diagnostic.store';

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
class StoreService<T extends Record<string, any>> {
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

  reset<K extends keyof T>(keys?: K[]): void {
    const prev = this.value;
    const next = structuredClone(this.value);

    if (keys && keys.length > 0) {
      keys.forEach((key) => {
        next[key] = structuredClone(this.initial[key]);
      });
    } else {
      Object.assign(next, structuredClone(this.initial));
    }

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

export interface IDiagnosticsChecksItem {
  state: 'error' | 'warning' | 'success';
  key: string;
  value: string;
}

export interface IDiagnosticsChecksStoreItem {
  order: number;
  code: string;
  title: string;
  description: string;
  state: 'loading' | 'warning' | 'success' | 'error' | 'skipped';
  items: Array<IDiagnosticsChecksItem>;
}

export interface StoreType {
  tabService: {
    current: string;
    all: string[];
  };
  bandwidthWidget: {
    loading: boolean;
    failed: boolean;
    data: { up: number; down: number };
  };
  trafficTotalWidget: {
    loading: boolean;
    failed: boolean;
    data: { downloadTotal: number; uploadTotal: number };
  };
  systemInfoWidget: {
    loading: boolean;
    failed: boolean;
    data: { connections: number; memory: number };
  };
  servicesInfoWidget: {
    loading: boolean;
    failed: boolean;
    data: { singbox: number; podkop: number };
  };
  sectionsWidget: {
    loading: boolean;
    failed: boolean;
    data: Podkop.OutboundGroup[];
    latencyFetching: boolean;
  };
  diagnosticsRunAction: {
    loading: boolean;
  };
  diagnosticsChecks: Array<IDiagnosticsChecksStoreItem>;
  diagnosticsActions: {
    restart: { loading: boolean };
    start: { loading: boolean };
    stop: { loading: boolean };
    enable: { loading: boolean };
    disable: { loading: boolean };
    globalCheck: { loading: boolean };
    viewLogs: { loading: boolean };
    showSingBoxConfig: { loading: boolean };
  };
  diagnosticsSystemInfo: {
    loading: boolean;
    podkop_version: string;
    podkop_latest_version: string;
    luci_app_version: string;
    sing_box_version: string;
    openwrt_version: string;
    device_model: string;
  };
}

const initialStore: StoreType = {
  tabService: {
    current: '',
    all: [],
  },
  bandwidthWidget: {
    loading: true,
    failed: false,
    data: { up: 0, down: 0 },
  },
  trafficTotalWidget: {
    loading: true,
    failed: false,
    data: { downloadTotal: 0, uploadTotal: 0 },
  },
  systemInfoWidget: {
    loading: true,
    failed: false,
    data: { connections: 0, memory: 0 },
  },
  servicesInfoWidget: {
    loading: true,
    failed: false,
    data: { singbox: 0, podkop: 0 },
  },
  sectionsWidget: {
    loading: true,
    failed: false,
    latencyFetching: false,
    data: [],
  },
  ...initialDiagnosticStore,
};

export const store = new StoreService<StoreType>(initialStore);
