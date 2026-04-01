// Paste into Chrome DevTools console on https://cursor.com/agents (while logged in).
// Fills the main composer input and focuses it. Submit with Enter or click your UI’s Run control.
// Cursor’s UI is React-controlled; setting .value via prototype + input event works for input[1].

(() => {
  const msg = [
    'Use the notion-bridge MCP server on this machine.',
    'Organize my Desktop safely:',
    '1) file_list with path my Desktop folder (non-recursive).',
    '2) dir_create Desktop/Organized if missing.',
    '3) Move loose files (not .app bundles) into Desktop/Organized/inbox-' +
      new Date().toISOString().slice(0, 10) +
      ' using file_move.',
    '4) Reply with a short summary of what moved.',
  ].join(' ');

  const inputs = Array.from(document.querySelectorAll('input'));
  const textInput = inputs.find((i) => i.type === 'text') || inputs[1];
  if (!textInput) {
    return 'error: no text input found';
  }
  const proto = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
  if (proto && proto.set) {
    proto.set.call(textInput, msg);
  } else {
    textInput.value = msg;
  }
  textInput.focus();
  textInput.dispatchEvent(new Event('input', { bubbles: true }));
  textInput.dispatchEvent(new Event('change', { bubbles: true }));
  return 'ok chars=' + textInput.value.length;
})();
