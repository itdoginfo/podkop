import { logger } from './logger.service';

export type LogFetcher = () => Promise<string> | string;

export interface NetShiftLogWatcherOptions {
  intervalMs?: number;
  onNewLog?: (line: string) => void;
}

export class NetShiftLogWatcher {
  private static instance: NetShiftLogWatcher;
  private fetcher?: LogFetcher;
  private onNewLog?: (line: string) => void;
  private intervalMs = 5000;
  private lastLines = new Set<string>();
  private timer?: ReturnType<typeof setInterval>;
  private running = false;
  private paused = false;

  private constructor() {
    if (typeof document !== 'undefined') {
      document.addEventListener('visibilitychange', () => {
        if (document.hidden) this.pause();
        else this.resume();
      });
    }
  }

  static getInstance(): NetShiftLogWatcher {
    if (!NetShiftLogWatcher.instance) {
      NetShiftLogWatcher.instance = new NetShiftLogWatcher();
    }
    return NetShiftLogWatcher.instance;
  }

  init(fetcher: LogFetcher, options?: NetShiftLogWatcherOptions): void {
    this.fetcher = fetcher;
    this.onNewLog = options?.onNewLog;
    this.intervalMs = options?.intervalMs ?? 5000;
    logger.info(
      '[NetShiftLogWatcher]',
      `initialized (interval: ${this.intervalMs}ms)`,
    );
  }

  async checkOnce(): Promise<void> {
    if (!this.fetcher) {
      logger.warn('[NetShiftLogWatcher]', 'fetcher not found');
      return;
    }

    if (this.paused) {
      logger.debug('[NetShiftLogWatcher]', 'skipped check — tab not visible');
      return;
    }

    try {
      const raw = await this.fetcher();
      const lines = raw.split('\n').filter(Boolean);

      for (const line of lines) {
        if (!this.lastLines.has(line)) {
          this.lastLines.add(line);
          this.onNewLog?.(line);
        }
      }

      if (this.lastLines.size > 500) {
        const arr = Array.from(this.lastLines);
        this.lastLines = new Set(arr.slice(-500));
      }
    } catch (err) {
      logger.error('[NetShiftLogWatcher]', 'failed to read logs:', err);
    }
  }

  start(): void {
    if (this.running) return;
    if (!this.fetcher) {
      logger.warn('[NetShiftLogWatcher]', 'attempted to start without fetcher');
      return;
    }

    this.running = true;
    this.timer = setInterval(() => this.checkOnce(), this.intervalMs);
    logger.info(
      '[NetShiftLogWatcher]',
      `started (interval: ${this.intervalMs}ms)`,
    );
  }

  stop(): void {
    if (!this.running) return;
    this.running = false;
    if (this.timer) clearInterval(this.timer);
    logger.info('[NetShiftLogWatcher]', 'stopped');
  }

  pause(): void {
    if (!this.running || this.paused) return;
    this.paused = true;
    logger.info('[NetShiftLogWatcher]', 'paused (tab not visible)');
  }

  resume(): void {
    if (!this.running || !this.paused) return;
    this.paused = false;
    logger.info('[NetShiftLogWatcher]', 'resumed (tab active)');
    this.checkOnce(); // сразу проверить, не появились ли новые логи
  }

  reset(): void {
    this.lastLines.clear();
    logger.info('[NetShiftLogWatcher]', 'log history reset');
  }
}
