import { logger } from './logger.service';

export type LogFetcher = () => Promise<string> | string;

export interface PodkopLogWatcherOptions {
  intervalMs?: number;
  onNewLog?: (line: string) => void;
}

export class PodkopLogWatcher {
  private static instance: PodkopLogWatcher;
  private fetcher?: LogFetcher;
  private onNewLog?: (line: string) => void;
  private intervalMs = 5000;
  private lastLines = new Set<string>();
  private timer?: ReturnType<typeof setInterval>;
  private running = false;

  private constructor() {}

  static getInstance(): PodkopLogWatcher {
    if (!PodkopLogWatcher.instance) {
      PodkopLogWatcher.instance = new PodkopLogWatcher();
    }
    return PodkopLogWatcher.instance;
  }

  init(fetcher: LogFetcher, options?: PodkopLogWatcherOptions): void {
    this.fetcher = fetcher;
    this.onNewLog = options?.onNewLog;
    this.intervalMs = options?.intervalMs ?? 5000;
  }

  async checkOnce(): Promise<void> {
    if (!this.fetcher) {
      logger.warn('[PodkopLogWatcher]', 'fetcher not found');
      return;
    }

    try {
      const raw = await this.fetcher();
      const lines = raw.split('\n').filter(Boolean);

      for (const line of lines) {
        if (!this.lastLines.has(line)) {
          this.lastLines.add(line);

          if (this.onNewLog) {
            this.onNewLog(line);
          }
        }
      }

      if (this.lastLines.size > 500) {
        const arr = Array.from(this.lastLines);
        this.lastLines = new Set(arr.slice(-500));
      }
    } catch (err) {
      logger.error('[PodkopLogWatcher]', 'failed to read logs:', err);
    }
  }

  start(): void {
    if (this.running) return;
    if (!this.fetcher) {
      logger.warn('[PodkopLogWatcher]', 'Try to start without fetcher.');
      return;
    }

    this.running = true;
    this.timer = setInterval(() => this.checkOnce(), this.intervalMs);
    logger.info(
      `[PodkopLogWatcher]', 'Started with interval ${this.intervalMs} ms`,
    );
  }

  stop(): void {
    if (!this.running) return;
    this.running = false;
    if (this.timer) clearInterval(this.timer);
    logger.info('[PodkopLogWatcher]', 'Stopped');
  }

  reset(): void {
    this.lastLines.clear();
    logger.info('[PodkopLogWatcher]', 'logs history was reset');
  }
}
