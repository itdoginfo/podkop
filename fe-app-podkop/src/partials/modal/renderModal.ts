import { renderButton } from '../button/renderButton';

export function renderModal(text: string) {
  return E(
    'div',
    { class: 'pdk-partial-modal__body' },
    E('div', {}, [
      E('pre', { class: 'pdk-partial-modal__content' }, E('code', {}, text)),

      E('div', { class: 'pdk-partial-modal__footer' }, [
        renderButton({
          classNames: ['cbi-button-apply'],
          text: _('Copy'),
          onClick: () => {},
        }),
        renderButton({
          classNames: ['cbi-button-remove'],
          text: _('Close'),
          onClick: ui.hideModal,
        }),
      ]),
    ]),
  );
}
