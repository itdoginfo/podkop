import { TabServiceInstance } from './tab.service';
import { store } from './store.service';
import { logger } from './logger.service';

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
}
