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
`;
