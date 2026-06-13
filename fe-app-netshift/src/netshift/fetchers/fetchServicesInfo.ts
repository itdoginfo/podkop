import { NetShiftShellMethods } from '../methods';
import { store } from '../services';

export async function fetchServicesInfo() {
  const [netshift, singbox] = await Promise.all([
    NetShiftShellMethods.getStatus(),
    NetShiftShellMethods.getSingBoxStatus(),
  ]);

  if (!netshift.success || !singbox.success) {
    store.set({
      servicesInfoWidget: {
        loading: false,
        failed: true,
        data: { singbox: 0, netshift: 0 },
      },
    });
  }

  if (netshift.success && singbox.success) {
    store.set({
      servicesInfoWidget: {
        loading: false,
        failed: false,
        data: {
          singbox: singbox.data.running,
          netshift: netshift.data.enabled,
        },
      },
    });
  }
}
