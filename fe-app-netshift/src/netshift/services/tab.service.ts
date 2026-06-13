type TabInfo = {
  el: HTMLElement;
  id: string;
  active: boolean;
};

type TabChangeCallback = (activeId: string | null, allTabs: TabInfo[]) => void;

export class TabService {
  private static instance: TabService;
  private observer: MutationObserver | null = null;
  private callback?: TabChangeCallback;
  private lastActiveId: string | null = null;

  private constructor() {
    this.init();
  }

  public static getInstance(): TabService {
    if (!TabService.instance) {
      TabService.instance = new TabService();
    }
    return TabService.instance;
  }

  private init() {
    this.observer = new MutationObserver(() => this.handleMutations());
    this.observer.observe(document.body, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ['class'],
    });

    // initial check
    this.notify();
  }

  private handleMutations() {
    this.notify();
  }

  private getTabsInfo(): TabInfo[] {
    const tabs = Array.from(
      document.querySelectorAll<HTMLElement>('.cbi-tab, .cbi-tab-disabled'),
    );
    return tabs.map((el) => ({
      el,
      id: el.dataset.tab || '',
      active:
        el.classList.contains('cbi-tab') &&
        !el.classList.contains('cbi-tab-disabled'),
    }));
  }

  private getActiveTabId(): string | null {
    const active = document.querySelector<HTMLElement>(
      '.cbi-tab:not(.cbi-tab-disabled)',
    );
    return active?.dataset.tab || null;
  }

  private notify() {
    const tabs = this.getTabsInfo();
    const activeId = this.getActiveTabId();

    if (activeId !== this.lastActiveId) {
      this.lastActiveId = activeId;
      this.callback?.(activeId, tabs);
    }
  }

  public onChange(callback: TabChangeCallback) {
    this.callback = callback;
    this.notify();
  }

  public getAllTabs(): TabInfo[] {
    return this.getTabsInfo();
  }

  public getActiveTab(): string | null {
    return this.getActiveTabId();
  }

  public disconnect() {
    this.observer?.disconnect();
    this.observer = null;
  }
}

export const TabServiceInstance = TabService.getInstance();
