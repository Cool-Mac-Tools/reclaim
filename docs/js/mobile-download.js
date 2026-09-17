(function () {
  'use strict';

  var footer = document.querySelector('[data-mobile-download]');
  var download = document.querySelector('a[download][href$=".dmg"]');
  if (!footer || !download) return;

  // iPadOS can identify as a Mac; a narrow desktop window is still a desktop.
  var isAppleMobile = /iPhone|iPad|iPod/i.test(navigator.userAgent) ||
    (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  var isMobile = isAppleMobile || /Android|Mobile/i.test(navigator.userAgent) ||
    Boolean(navigator.userAgentData && navigator.userAgentData.mobile);
  if (!isMobile) return;

  var downloadURL = new URL(download.getAttribute('href'), 'https://reclaimac.com').href;
  var message = 'Download Reclaim for your Mac: ' + downloadURL +
    '\n\nOpen this link on your Mac to install. Requires Apple Silicon and macOS 14 or later.';
  var textLink = footer.querySelector('[data-send-text]');
  var emailLink = footer.querySelector('[data-send-email]');
  var status = footer.querySelector('[data-send-status]');
  var copyButton = footer.querySelector('[data-copy-download]');
  var fallback = footer.querySelector('[data-copy-fallback]');
  var input = footer.querySelector('[data-download-url]');
  var root = document.documentElement;
  var dismissKey = 'reclaim-mobile-download-dismissed';
  var returnFocus;

  // Messages on iOS uses an ampersand before body; Android uses a query string.
  textLink.href = 'sms:' + (isAppleMobile ? '&' : '?') + 'body=' + encodeURIComponent(message);
  emailLink.href = 'mailto:?subject=' + encodeURIComponent('Reclaim for your Mac') +
    '&body=' + encodeURIComponent(message);
  input.value = downloadURL;

  function updateSpace() {
    root.style.setProperty('--mobile-download-height', footer.hidden ? '0px' : footer.offsetHeight + 'px');
  }

  function showFooter(trigger) {
    footer.hidden = false;
    root.classList.add('mobile-download-visible');
    updateSpace();
    if (trigger) {
      returnFocus = trigger;
      textLink.focus({ preventScroll: true });
    }
  }

  function dismissFooter() {
    footer.hidden = true;
    root.classList.remove('mobile-download-visible');
    updateSpace();
    try { sessionStorage.setItem(dismissKey, 'true'); } catch (_) { /* Storage may be blocked. */ }
    if (returnFocus) returnFocus.focus({ preventScroll: true });
  }

  var dismissed = false;
  try { dismissed = sessionStorage.getItem(dismissKey) === 'true'; } catch (_) { /* Still offer the link. */ }
  if (!dismissed) showFooter();

  footer.querySelector('[data-mobile-download-dismiss]').addEventListener('click', dismissFooter);
  footer.addEventListener('keydown', function (event) {
    if (event.key === 'Escape') {
      event.preventDefault();
      dismissFooter();
    }
  });

  document.querySelectorAll('a[download]').forEach(function (link) {
    if (link.getAttribute('href') !== download.getAttribute('href')) return;
    link.addEventListener('click', function (event) {
      if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      showFooter(link);
    });
  });

  [textLink, emailLink].forEach(function (link) {
    link.addEventListener('click', function () {
      status.textContent = 'Choose yourself as the recipient, then send.';
    });
  });

  copyButton.addEventListener('click', async function () {
    try {
      await navigator.clipboard.writeText(downloadURL);
      fallback.hidden = true;
      status.textContent = 'Link copied. Paste it into any message.';
    } catch (_) {
      fallback.hidden = false;
      input.focus({ preventScroll: true });
      input.select();
      status.textContent = 'Press and hold the link below to copy.';
    }
    updateSpace();
  });

  if ('ResizeObserver' in window) new ResizeObserver(updateSpace).observe(footer);
  window.addEventListener('resize', updateSpace);
})();
