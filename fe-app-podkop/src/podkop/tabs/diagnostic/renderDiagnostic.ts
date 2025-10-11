export function renderDiagnostic() {
  return E(
    'div',
    { id: 'diagnostic-status', class: 'pdk_diagnostic-page' },
    E(
      'div',
      {
        class: 'pdk_diagnostic-page__checks',
        id: 'pdk_diagnostic-page-checks',
      },
      // [
      //   renderCheckSection({
      //     state: 'loading',
      //     title: _('DNS Checks'),
      //     description: _('Checking, please wait'),
      //     items: [],
      //   }),
      //   renderCheckSection({
      //     state: 'warning',
      //     title: _('DNS Checks'),
      //     description: _('Some checks was failed'),
      //     items: [],
      //   }),
      //   renderCheckSection({
      //     state: 'error',
      //     title: _('DNS Checks'),
      //     description: _('Checks was failed'),
      //     items: [],
      //   }),
      //   renderCheckSection({
      //     state: 'success',
      //     title: _('DNS Checks'),
      //     description: _('Checks was passed'),
      //     items: [],
      //   }),
      //   renderCheckSection({
      //     state: 'skipped',
      //     title: _('DNS Checks'),
      //     description: _('Checks was skipped'),
      //     items: [],
      //   }),
      // ],
    ),
  );
}
