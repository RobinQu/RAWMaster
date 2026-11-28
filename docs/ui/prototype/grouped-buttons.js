'use strict';

document.addEventListener('keydown', (event) => {
  if (event.defaultPrevented || event.altKey || event.metaKey || event.ctrlKey) return;
  if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
  const button = event.target.closest('.button-group > button, .workflow-switch > button');
  if (!button) return;
  const group = button.parentElement;
  const buttons = Array.from(group.querySelectorAll(':scope > button:enabled'));
  const current = buttons.indexOf(button);
  if (current < 0) return;
  const step = (event.key === 'ArrowLeft' ? -1 : 1) * (getComputedStyle(group).direction === 'rtl' ? -1 : 1);
  const index = event.key === 'Home' ? 0 : event.key === 'End' ? buttons.length - 1
    : (current + step + buttons.length) % buttons.length;
  event.preventDefault();
  if (index === current) return;
  buttons[index].focus();
  if (group.hasAttribute('data-select-on-arrow')) buttons[index].click();
});
