interface IGetMetaProps {
  allGood: boolean;
  atLeastOneGood: boolean;
}

export function getMeta({ allGood, atLeastOneGood }: IGetMetaProps): {
  description: string;
  state: 'loading' | 'warning' | 'success' | 'error' | 'skipped';
} {
  if (allGood) {
    return {
      state: 'success',
      description: _('Checks passed'),
    };
  }

  if (atLeastOneGood) {
    return {
      state: 'warning',
      description: _('Issues detected'),
    };
  }

  return {
    state: 'error',
    description: _('Checks failed'),
  };
}
