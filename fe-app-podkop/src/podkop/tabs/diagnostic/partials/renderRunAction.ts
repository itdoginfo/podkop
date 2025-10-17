import { renderButton } from '../../../../partials';
import { renderSearchIcon24 } from '../../../../icons';

interface IRenderDiagnosticRunActionProps {
  loading: boolean;
  click: () => void;
}

export function renderRunAction({
  loading,
  click,
}: IRenderDiagnosticRunActionProps) {
  return E('div', { class: 'pdk_diagnostic-page__run_check_wrapper' }, [
    renderButton({
      text: _('Run Diagnostic'),
      onClick: click,
      icon: renderSearchIcon24,
      loading,
      classNames: ['cbi-button-apply'],
    }),
  ]);
}
