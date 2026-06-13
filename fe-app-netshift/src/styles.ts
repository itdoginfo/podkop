// language=CSS
import { DashboardTab, DiagnosticTab, ManagerTab } from './netshift';
import { PartialStyles } from './partials';

export const GlobalStyles = `
/*
 * NetShift design tokens (Stage 1 foundation — task-024).
 * Each token layers over the LuCI theme var (with a hardcoded fallback) so
 * themes still win. Reused by the custom tabs and the form redesigns
 * (task-025/026). Keep these names stable.
 */
:root,
.cbi-map {
    --ns-card-border: var(--background-color-low, lightgray);
    --ns-card-border-width: 2px;
    --ns-card-radius: 4px;
    --ns-gap: 10px;
    --ns-card-padding: var(--ns-gap);
    --ns-success: var(--success-color-medium, #28a745);
    --ns-warning: var(--warn-color-medium, #f0ad4e);
    --ns-error: var(--error-color-medium, #dc3545);
    --ns-info: var(--primary-color-high, #2196f3);
}

/*
 * Shared card primitive. Mirrors the Manager component card look
 * (2px solid border, 4px radius, 10px padding, overflow-safe min-width:0).
 * Defined BEFORE the per-tab styles so colored-border modifiers
 * (e.g. .pdk_diagnostic_alert--warning) still win via source order.
 */
.card {
    border: var(--ns-card-border-width) solid var(--ns-card-border);
    border-radius: var(--ns-card-radius);
    padding: var(--ns-card-padding);
    min-width: 0;
}

${DashboardTab.styles}
${DiagnosticTab.styles}
${ManagerTab.styles}
${PartialStyles}


/* Hide extra H3 for settings tab */
#cbi-netshift-settings > h3 {
    display: none;
}

/* Hide extra H3 for sections tab */
#cbi-netshift-section > h3:nth-child(1) {
    display: none;
}

/* Vertical align for remove section action button */
#cbi-netshift-section > .cbi-section-remove {
    margin-bottom: -32px;
}

/*
 * Sections (connection) form — native CBI option-group tabs styled as a
 * card (task-025). Reuses task-024's --ns-* tokens. The tab strip
 * (ul.cbi-tabmenu) sits on top; each tab pane (.cbi-section-node-tabbed)
 * reads as the card body. depends()-driven auto-hide of tabs is unaffected.
 */
#cbi-netshift-section .cbi-section-node-tabbed {
    border: var(--ns-card-border-width) solid var(--ns-card-border);
    border-radius: var(--ns-card-radius);
    padding: var(--ns-card-padding);
    min-width: 0;
}

#cbi-netshift-section ul.cbi-tabmenu {
    margin-bottom: var(--ns-gap);
}

/*
 * Settings form — native CBI option-group tabs styled as a card (task-026).
 * Reuses task-024's --ns-* tokens and mirrors the #cbi-netshift-section
 * pattern above. The tab strip (ul.cbi-tabmenu) sits on top; each tab pane
 * (.cbi-section-node-tabbed) reads as the card body. depends()-driven
 * auto-hide of tabs is unaffected. The existing
 * #cbi-netshift-settings > h3 hide rule above stays valid.
 */
#cbi-netshift-settings .cbi-section-node-tabbed {
    border: var(--ns-card-border-width) solid var(--ns-card-border);
    border-radius: var(--ns-card-radius);
    padding: var(--ns-card-padding);
    min-width: 0;
}

#cbi-netshift-settings ul.cbi-tabmenu {
    margin-bottom: var(--ns-gap);
}

/* Centered class helper */
.centered {
    display: flex;
    align-items: center;
    justify-content: center;
}

/* Rotate class helper */
.rotate {
    animation: spin 1s linear infinite;
}

@keyframes spin {
    from { transform: rotate(0deg); }
    to { transform: rotate(360deg); }
}

/* Skeleton styles*/
.skeleton {
    background-color: var(--background-color-low, #e0e0e0);
    border-radius: 4px;
    position: relative;
    overflow: hidden;
}

.skeleton::after {
    content: '';
    position: absolute;
    top: 0;
    left: -150%;
    width: 150%;
    height: 100%;
    background: linear-gradient(
            90deg,
            transparent,
            rgba(255, 255, 255, 0.4),
            transparent
    );
    animation: skeleton-shimmer 1.6s infinite;
}

@keyframes skeleton-shimmer {
    100% {
        left: 150%;
    }
}
/* Toast */
.toast-container {
    position: fixed;
    bottom: 30px;
    left: 50%;
    transform: translateX(-50%);
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 10px;
    z-index: 9999;
    font-family: system-ui, sans-serif;
}

.toast {
    opacity: 0;
    transform: translateY(10px);
    transition: opacity 0.3s ease, transform 0.3s ease;
    padding: 10px 16px;
    border-radius: 6px;
    color: #fff;
    font-size: 14px;
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.2);
    min-width: 220px;
    max-width: 340px;
    text-align: center;
}

.toast-success {
    background-color: var(--ns-success, #28a745);
}

.toast-error {
    background-color: var(--ns-error, #dc3545);
}

.toast-warning {
    background-color: var(--ns-warning, #f0ad4e);
}

.toast-info {
    background-color: var(--ns-info, #2196f3);
}

.toast.visible {
    opacity: 1;
    transform: translateY(0);
}
`;
