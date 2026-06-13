import { StoreType } from '../../services';

export const initialManagerStore: Pick<
  StoreType,
  'managerActions' | 'managerChecks'
> = {
  managerActions: {
    netshiftCheck: { loading: false },
    netshiftUpdate: { loading: false },
    singBoxStockCheck: { loading: false },
    singBoxStockAction: { loading: false },
    singBoxExtendedCheck: { loading: false },
    singBoxExtendedAction: { loading: false },
  },
  managerChecks: {
    netshift: { status: null, latest_version: '' },
    sing_box_stock: { status: null, latest_version: '' },
    sing_box_extended: { status: null, latest_version: '' },
  },
};
