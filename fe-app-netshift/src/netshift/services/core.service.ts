import { TabServiceInstance } from './tab.service';
import { store } from './store.service';
import { logger } from './logger.service';
import { NetShiftLogWatcher } from './netshiftLogWatcher.service';
import { NetShiftShellMethods } from '../methods';
import {
  createLogErrorBatcher,
  type LogErrorBatch,
} from '../../helpers/summarizeLogErrors';

export function coreService() {
  TabServiceInstance.onChange((activeId, tabs) => {
    logger.info('[TAB]', activeId);
    store.set({
      tabService: {
        current: activeId || '',
        all: tabs.map((tab) => tab.id),
      },
    });
  });

  const watcher = NetShiftLogWatcher.getInstance();

  // The error lines of one poll of the log become one group of notifications.
  const showErrors = (batch: LogErrorBatch) => {
    batch.shown.forEach((item) => {
      ui.addNotification(
        'NetShift Error',
        E(
          'div',
          {},
          item.count > 1 ? `${item.message} (×${item.count})` : item.message,
        ),
        'error',
      );
    });

    if (batch.hiddenLines > 0) {
      ui.addNotification(
        'NetShift Error',
        E(
          'div',
          {},
          `${_('And more errors')}: ${batch.hiddenLines}. ${_('See the log')}`,
        ),
        'error',
      );
    }
  };
  const errorBatcher = createLogErrorBatcher(showErrors);

  watcher.init(
    async () => {
      const logs = await NetShiftShellMethods.checkLogs();

      if (logs.success) {
        return logs.data as string;
      }

      return '';
    },
    {
      intervalMs: 3000,
      onNewLog: (line) => {
        if (
          line.toLowerCase().includes('[error]') ||
          line.toLowerCase().includes('[fatal]')
        ) {
          errorBatcher.push(line);
        }
      },
    },
  );

  watcher.start();
}
