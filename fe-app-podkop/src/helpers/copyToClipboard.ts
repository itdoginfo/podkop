import { showToast } from './showToast';

export function copyToClipboard(text: string) {
  const textarea = document.createElement('textarea');
  textarea.value = text;
  document.body.appendChild(textarea);
  textarea.select();
  try {
    document.execCommand('copy');
    showToast(_('Successfully copied!'), 'success');
  } catch (_err) {
    showToast(_('Failed to copy!'), 'error');
    console.error('copyToClipboard - e', _err);
  }
  document.body.removeChild(textarea);
}
