import { renderButton } from '../button/renderButton';
import { copyToClipboard } from '../../helpers/copyToClipboard';
import { downloadAsTxt } from '../../helpers/downloadAsTxt';

export function renderModal(text: string, name: string) {
  return E(
    'div',
    { class: 'pdk-partial-modal__body' },
    E('div', {}, [
      E('pre', { class: 'pdk-partial-modal__content' }, E('code', {}, text)),

      E('div', { class: 'pdk-partial-modal__footer' }, [
        renderButton({
          classNames: ['cbi-button-apply'],
          text: _('Download'),
          onClick: () => downloadAsTxt(text, name),
        }),
        renderButton({
          classNames: ['cbi-button-apply'],
          text: _('Copy'),
          onClick: () =>
            copyToClipboard(` \`\`\`${name} \n ${text}  \n \`\`\``),
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
