import { onMount } from '../../../helpers';

export async function initDiagnosticController(): Promise<void> {
  onMount('diagnostic-status').then(() => {
    console.log('diagnostic controller initialized.');
  });
}
