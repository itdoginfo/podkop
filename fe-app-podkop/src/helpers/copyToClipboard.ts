interface CopyToClipboardResponse {
  success: boolean;
  message: string;
}

export function copyToClipboard(text: string): CopyToClipboardResponse {
  const textarea = document.createElement('textarea');
  textarea.value = text;
  document.body.appendChild(textarea);
  textarea.select();

  try {
    document.execCommand('copy');

    return {
      success: true,
      message: 'Copied!',
    };
  } catch (err) {
    const error = err as Error;

    return {
      success: false,
      message: `Failed to copy: ${error.message}`,
    };
  } finally {
    document.body.removeChild(textarea);
  }
}
