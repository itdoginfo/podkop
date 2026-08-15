// language=CSS
import { DashboardTab, DiagnosticTab } from './podkop';
import { PartialStyles } from './partials';

export const GlobalStyles = `
${DashboardTab.styles}
${DiagnosticTab.styles}
${PartialStyles}


/* Hide extra H3 for settings tab */
#cbi-podkop-settings > h3 {
    display: none;
}

/* Hide extra H3 for sections tab */
#cbi-podkop-section > h3:nth-child(1) {
    display: none;
}

/* Vertical align for remove section action button */
#cbi-podkop-section > .cbi-section-remove {
    margin-bottom: -32px;
}

/* Selector proxy link editor */
.cbi-dynlist[id$='.selector_proxy_links'] > .item > span {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.pdk-selector-link-edit {
    flex: 0 0 auto;
    margin-left: auto;
    margin-right: 1.5rem;
    padding: 0.15rem 0.5rem;
}

.pdk-selector-link-editor__input {
    box-sizing: border-box;
    min-height: 8rem;
    width: 100%;
    resize: vertical;
    overflow-wrap: anywhere;
}

.pdk-selector-link-editor__error {
    margin: 0.5rem 0;
    color: var(--danger-color, #d12f2f);
}

.pdk-selector-link-editor .right {
    display: flex;
    justify-content: flex-end;
    gap: 0.5rem;
    margin-top: 1rem;
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
    background-color: #28a745;
}

.toast-error {
    background-color: #dc3545;
}

.toast.visible {
    opacity: 1;
    transform: translateY(0);
}
`;
