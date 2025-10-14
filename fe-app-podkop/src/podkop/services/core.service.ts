import { TabServiceInstance } from './tab.service';
import { store } from './store.service';

export function coreService() {
  TabServiceInstance.onChange((activeId, tabs) => {
    store.set({
      tabService: {
        current: activeId || '',
        all: tabs.map((tab) => tab.id),
      },
    });
  });
}
