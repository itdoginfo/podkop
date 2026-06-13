import { downloadAsTxt } from '../../helpers/downloadAsTxt';

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

export class Logger {
  private logs: string[] = [];
  private readonly levels: LogLevel[] = ['debug', 'info', 'warn', 'error'];

  private format(level: LogLevel, ...args: unknown[]): string {
    return `[${level.toUpperCase()}] ${args.join(' ')}`;
  }

  private push(level: LogLevel, ...args: unknown[]): void {
    if (!this.levels.includes(level)) level = 'info';
    const message = this.format(level, ...args);
    this.logs.push(message);

    switch (level) {
      case 'error':
        console.error(message);
        break;
      case 'warn':
        console.warn(message);
        break;
      case 'info':
        console.info(message);
        break;
      default:
        console.log(message);
    }
  }

  debug(...args: unknown[]): void {
    this.push('debug', ...args);
  }

  info(...args: unknown[]): void {
    this.push('info', ...args);
  }

  warn(...args: unknown[]): void {
    this.push('warn', ...args);
  }

  error(...args: unknown[]): void {
    this.push('error', ...args);
  }

  clear(): void {
    this.logs = [];
  }

  getLogs(): string {
    return this.logs.join('\n');
  }

  download(filename = 'logs.txt'): void {
    if (typeof document === 'undefined') {
      console.warn('Logger.download() доступен только в браузере');
      return;
    }
    downloadAsTxt(this.getLogs(), filename);
  }
}

export const logger = new Logger();
