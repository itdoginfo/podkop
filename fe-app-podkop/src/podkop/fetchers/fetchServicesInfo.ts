import { PodkopShellMethods } from '../methods';
import { store } from '../services';

export async function fetchServicesInfo() {
  const [podkop, singbox] = await Promise.all([
    PodkopShellMethods.getStatus(),
    PodkopShellMethods.getSingBoxStatus(),
  ]);

  if (!podkop.success || !singbox.success) {
    store.set({
      servicesInfoWidget: {
        loading: false,
        failed: true,
        data: { singbox: 0, podkop: 0 },
      },
    });
  }

  if (podkop.success && singbox.success) {
    store.set({
      servicesInfoWidget: {
        loading: false,
        failed: false,
        data: { singbox: singbox.data.running, podkop: podkop.data.enabled },
      },
    });
  }
}
