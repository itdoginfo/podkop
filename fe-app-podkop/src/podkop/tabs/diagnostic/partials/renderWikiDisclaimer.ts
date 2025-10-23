import { renderBookOpenTextIcon24 } from '../../../../icons';
import { renderButton } from '../../../../partials';
import { insertIf } from '../../../../helpers';

export function renderWikiDisclaimer(kind: 'default' | 'error' | 'warning') {
  const iconWrap = E('span', {
    class: 'pdk_diagnostic-page__right-bar__wiki__icon',
  });
  iconWrap.appendChild(renderBookOpenTextIcon24());

  const className = [
    'pdk_diagnostic-page__right-bar__wiki',
    ...insertIf(kind === 'error', [
      'pdk_diagnostic-page__right-bar__wiki--error',
    ]),
    ...insertIf(kind === 'warning', [
      'pdk_diagnostic-page__right-bar__wiki--warning',
    ]),
  ].join(' ');

  return E('div', { class: className }, [
    E('div', { class: 'pdk_diagnostic-page__right-bar__wiki__content' }, [
      iconWrap,
      E('div', { class: 'pdk_diagnostic-page__right-bar__wiki__texts' }, [
        E('b', {}, _('Troubleshooting')),
        E('div', {}, _('Do not panic, everything can be fixed, just...')),
      ]),
    ]),
    renderButton({
      classNames: ['cbi-button-save'],
      text: _('Visit Wiki'),
      onClick: () =>
        window.open(
          'https://podkop.net/docs/troubleshooting/?utm_source=podkop',
          '_blank',
          'noopener,noreferrer',
        ),
    }),
  ]);
}
