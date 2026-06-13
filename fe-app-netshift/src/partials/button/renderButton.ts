import { insertIf } from '../../helpers';
import { renderLoaderCircleIcon24 } from '../../icons';

interface IRenderButtonProps {
  classNames?: string[];
  disabled?: boolean;
  loading?: boolean;
  icon?: () => SVGSVGElement;
  onClick: () => void;
  text: string;
}

export function renderButton({
  classNames = [],
  disabled,
  loading,
  onClick,
  text,
  icon,
}: IRenderButtonProps) {
  const hasIcon = !!loading || !!icon;

  function getWrappedIcon() {
    const iconWrap = E('span', {
      class: 'pdk-partial-button__icon',
    });

    if (loading) {
      iconWrap.appendChild(renderLoaderCircleIcon24());

      return iconWrap;
    }

    if (icon) {
      iconWrap.appendChild(icon());

      return iconWrap;
    }

    return iconWrap;
  }

  function getClass() {
    return [
      'btn',
      'pdk-partial-button',
      ...insertIf(Boolean(disabled), ['pdk-partial-button--disabled']),
      ...insertIf(Boolean(loading), ['pdk-partial-button--loading']),
      ...insertIf(Boolean(hasIcon), ['pdk-partial-button--with-icon']),
      ...classNames,
    ]
      .filter(Boolean)
      .join(' ');
  }

  function getDisabled() {
    if (loading || disabled) {
      return true;
    }

    return undefined;
  }

  return E(
    'button',
    { class: getClass(), disabled: getDisabled(), click: onClick },
    [...insertIf(hasIcon, [getWrappedIcon()]), E('span', {}, text)],
  );
}
