interface IRenderDiagnosticRunActionProps {
  loading: boolean;
  click: () => void;
}

export function renderRunAction({
  loading,
  click,
}: IRenderDiagnosticRunActionProps) {
  return E('div', { class: 'pdk_diagnostic-page__run_check_wrapper' }, [
    E(
      'button',
      { class: 'btn', disabled: loading ? true : undefined, click },
      loading ? _('Running... please wait') : _('Run Diagnostic'),
    ),
  ]);
}
