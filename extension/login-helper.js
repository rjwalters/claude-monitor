// Login helper - shows a toast when opened via "Open All Accounts" feature
(function() {
  console.log('[Claude Monitor] Login helper loaded, hash:', window.location.hash);

  // Check for account name in URL fragment
  const hash = window.location.hash;
  const match = hash.match(/cm_account=([^&]+)/);

  if (!match) {
    console.log('[Claude Monitor] No cm_account in hash, skipping toast');
    return;
  }

  console.log('[Claude Monitor] Found account:', match[1]);

  const accountName = decodeURIComponent(match[1]);

  // Create toast element
  const toast = document.createElement('div');
  toast.id = 'claude-monitor-toast';
  toast.innerHTML = `
    <div style="
      position: fixed;
      top: 20px;
      left: 50%;
      transform: translateX(-50%);
      background: #1a1a2e;
      color: #fff;
      padding: 16px 24px;
      border-radius: 12px;
      box-shadow: 0 4px 20px rgba(0,0,0,0.3);
      z-index: 999999;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      font-size: 14px;
      display: flex;
      align-items: center;
      gap: 12px;
      max-width: 90vw;
    ">
      <span style="font-size: 20px;">👤</span>
      <div>
        <div style="font-weight: 600; margin-bottom: 2px;">Log in as:</div>
        <div style="color: #a5b4fc; font-size: 16px;">${accountName}</div>
      </div>
      <button id="claude-monitor-toast-close" style="
        background: none;
        border: none;
        color: #888;
        font-size: 18px;
        cursor: pointer;
        padding: 0 0 0 8px;
        line-height: 1;
      ">&times;</button>
    </div>
  `;

  // Add to page when DOM is ready
  function addToast() {
    document.body.appendChild(toast);

    // Close button handler
    document.getElementById('claude-monitor-toast-close').addEventListener('click', () => {
      toast.remove();
    });

    // Auto-remove after 30 seconds
    setTimeout(() => {
      if (toast.parentNode) {
        toast.style.transition = 'opacity 0.3s';
        toast.style.opacity = '0';
        setTimeout(() => toast.remove(), 300);
      }
    }, 30000);

    // Clean up the URL fragment
    history.replaceState(null, '', window.location.pathname + window.location.search);
  }

  if (document.body) {
    addToast();
  } else {
    document.addEventListener('DOMContentLoaded', addToast);
  }
})();
