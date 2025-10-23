interface IRenderWidgetProps {
  loading: boolean;
  failed: boolean;
  title: string;
  items: Array<{
    key: string;
    value: string;
    attributes?: {
      class?: string;
    };
  }>;
}

function renderFailedState() {
  return E(
    'div',
    {
      id: '',
      style: 'height: 78px',
      class: 'pdk_dashboard-page__widgets-section__item centered',
    },
    _('Currently unavailable'),
  );
}

function renderLoadingState() {
  return E(
    'div',
    {
      id: '',
      style: 'height: 78px',
      class: 'pdk_dashboard-page__widgets-section__item skeleton',
    },
    '',
  );
}

function renderDefaultState({ title, items }: IRenderWidgetProps) {
  return E('div', { class: 'pdk_dashboard-page__widgets-section__item' }, [
    E(
      'b',
      { class: 'pdk_dashboard-page__widgets-section__item__title' },
      title,
    ),
    ...items.map((item) =>
      E(
        'div',
        {
          class: `pdk_dashboard-page__widgets-section__item__row ${item?.attributes?.class || ''}`,
        },
        [
          E(
            'span',
            { class: 'pdk_dashboard-page__widgets-section__item__row__key' },
            `${item.key}: `,
          ),
          E(
            'span',
            { class: 'pdk_dashboard-page__widgets-section__item__row__value' },
            item.value,
          ),
        ],
      ),
    ),
  ]);
}

export function renderWidget(props: IRenderWidgetProps) {
  if (props.loading) {
    return renderLoadingState();
  }

  if (props.failed) {
    return renderFailedState();
  }

  return renderDefaultState(props);
}
