import { renderButton } from '../../../../partials';

interface IRenderSectionsToolbarProps {
  // Hidden when the dashboard has no subscription section to refresh.
  visible: boolean;
  refreshing: boolean;
  onRefreshAll: () => void;
}

// Header above the sections grid: a "refresh all subscriptions" button shown
// only when at least one configured section is a subscription.
export function renderSectionsToolbar({
  visible,
  refreshing,
  onRefreshAll,
}: IRenderSectionsToolbarProps) {
  if (!visible) {
    return E('div', {});
  }

  return E('div', { class: 'pdk_dashboard-page__sections-toolbar' }, [
    E(
      'div',
      { class: 'pdk_dashboard-page__sections-toolbar__title' },
      _('Subscriptions'),
    ),
    renderButton({
      text: _('Refresh all subscriptions'),
      loading: refreshing,
      onClick: onRefreshAll,
      classNames: ['dashboard-refresh-all-subscriptions'],
    }),
  ]);
}
