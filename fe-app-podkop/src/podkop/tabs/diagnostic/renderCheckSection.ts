import {
  renderLoaderCircleIcon24,
  renderShieldAlertIcon24,
  renderShieldCheckIcon24,
  renderShieldIcon24,
  renderShieldXIcon24,
} from '../../../icons';
import { IDiagnosticsChecksStoreItem } from '../../../store';

type IRenderCheckSectionProps = IDiagnosticsChecksStoreItem;

function renderCheckSummary(items: IRenderCheckSectionProps['items']) {
  if (!items.length) {
    return E('div', {}, '');
  }

  const renderedItems = items.map((item) =>
    E(
      'div',
      {
        class: `pdk_diagnostic_alert__summary__item pdk_diagnostic_alert__summary__item--${item.state}`,
      },
      [E('b', {}, item.key), E('div', {}, item.value)],
    ),
  );

  return E('div', { class: 'pdk_diagnostic_alert__summary' }, renderedItems);
}

function renderLoadingState(props: IRenderCheckSectionProps) {
  const iconWrap = E('span', { class: 'pdk_diagnostic_alert__icon' });
  iconWrap.appendChild(renderLoaderCircleIcon24());

  return E(
    'div',
    { class: 'pdk_diagnostic_alert pdk_diagnostic_alert--loading' },
    [
      iconWrap,
      E('div', { class: 'pdk_diagnostic_alert__content' }, [
        E('b', { class: 'pdk_diagnostic_alert__title' }, props.title),
        E(
          'div',
          { class: 'pdk_diagnostic_alert__description' },
          props.description,
        ),
      ]),
      E('div', {}, ''),
      renderCheckSummary(props.items),
    ],
  );
}

function renderWarningState(props: IRenderCheckSectionProps) {
  const iconWrap = E('span', { class: 'pdk_diagnostic_alert__icon' });
  iconWrap.appendChild(renderShieldAlertIcon24());

  return E(
    'div',
    { class: 'pdk_diagnostic_alert pdk_diagnostic_alert--warning' },
    [
      iconWrap,
      E('div', { class: 'pdk_diagnostic_alert__content' }, [
        E('b', { class: 'pdk_diagnostic_alert__title' }, props.title),
        E(
          'div',
          { class: 'pdk_diagnostic_alert__description' },
          props.description,
        ),
      ]),
      E('div', {}, ''),
      renderCheckSummary(props.items),
    ],
  );
}

function renderErrorState(props: IRenderCheckSectionProps) {
  const iconWrap = E('span', { class: 'pdk_diagnostic_alert__icon' });
  iconWrap.appendChild(renderShieldXIcon24());

  return E(
    'div',
    { class: 'pdk_diagnostic_alert pdk_diagnostic_alert--error' },
    [
      iconWrap,
      E('div', { class: 'pdk_diagnostic_alert__content' }, [
        E('b', { class: 'pdk_diagnostic_alert__title' }, props.title),
        E(
          'div',
          { class: 'pdk_diagnostic_alert__description' },
          props.description,
        ),
      ]),
      E('div', {}, ''),
      renderCheckSummary(props.items),
    ],
  );
}

function renderSuccessState(props: IRenderCheckSectionProps) {
  const iconWrap = E('span', { class: 'pdk_diagnostic_alert__icon' });
  iconWrap.appendChild(renderShieldCheckIcon24());

  return E(
    'div',
    { class: 'pdk_diagnostic_alert pdk_diagnostic_alert--success' },
    [
      iconWrap,
      E('div', { class: 'pdk_diagnostic_alert__content' }, [
        E('b', { class: 'pdk_diagnostic_alert__title' }, props.title),
        E(
          'div',
          { class: 'pdk_diagnostic_alert__description' },
          props.description,
        ),
      ]),
      E('div', {}, ''),
      renderCheckSummary(props.items),
    ],
  );
}

function renderSkippedState(props: IRenderCheckSectionProps) {
  const iconWrap = E('span', { class: 'pdk_diagnostic_alert__icon' });
  iconWrap.appendChild(renderShieldIcon24());

  return E(
    'div',
    { class: 'pdk_diagnostic_alert pdk_diagnostic_alert--skipped' },
    [
      iconWrap,
      E('div', { class: 'pdk_diagnostic_alert__content' }, [
        E('b', { class: 'pdk_diagnostic_alert__title' }, props.title),
        E(
          'div',
          { class: 'pdk_diagnostic_alert__description' },
          props.description,
        ),
      ]),
      E('div', {}, ''),
      renderCheckSummary(props.items),
    ],
  );
}

export function renderCheckSection(props: IRenderCheckSectionProps) {
  if (props.state === 'loading') {
    return renderLoadingState(props);
  }

  if (props.state === 'warning') {
    return renderWarningState(props);
  }

  if (props.state === 'error') {
    return renderErrorState(props);
  }

  if (props.state === 'success') {
    return renderSuccessState(props);
  }

  if (props.state === 'skipped') {
    return renderSkippedState(props);
  }

  return E('div', {}, 'Not implement yet');
}
